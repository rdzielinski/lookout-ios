import Foundation

/// Polls OBD-II PIDs on an adaptive timer and feeds parsed responses into the DrivingDataStore.
///
/// Three priority tiers:
/// - High: RPM, Speed, MAF, Throttle — every cycle
/// - Medium: Engine Load, Accel Pedal — every 2nd cycle
/// - Low: Coolant/Intake/Ambient temps, Fuel Level, Baro — every 5th cycle
@Observable
final class OBDService: @unchecked Sendable {

    private(set) var isPolling = false
    private(set) var pollRate: Double = 0  // PIDs per second
    private(set) var errorCount: Int = 0
    private(set) var lastError: String?

    private var adapter: OBDAdapter?
    private var dataStore: DrivingDataStore?
    private var pollingTask: Task<Void, Never>?
    private var cycleCount: Int = 0

    /// Target interval between complete polling cycles (seconds).
    /// Adaptive — speeds up when responses are fast, slows on errors.
    private var pollInterval: TimeInterval = 0.1

    // MARK: - Public API

    func start(adapter: OBDAdapter, dataStore: DrivingDataStore) {
        self.adapter = adapter
        self.dataStore = dataStore
        self.errorCount = 0
        self.lastError = nil
        self.cycleCount = 0

        isPolling = true

        pollingTask = Task { [weak self] in
            await self?.pollingLoop()
        }
    }

    func stop() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Polling Loop

    private func pollingLoop() async {
        while isPolling && !Task.isCancelled {
            let cycleStart = Date()
            cycleCount += 1
            var pidCount = 0

            // High priority — every cycle
            for pid in PIDCatalog.highPriority {
                guard isPolling && !Task.isCancelled else { return }
                if await pollPID(pid) { pidCount += 1 }
            }

            // Medium priority — every 2nd cycle
            if cycleCount % 2 == 0 {
                for pid in PIDCatalog.mediumPriority {
                    guard isPolling && !Task.isCancelled else { return }
                    if await pollPID(pid) { pidCount += 1 }
                }
            }

            // Low priority — every 5th cycle
            if cycleCount % 5 == 0 {
                for pid in PIDCatalog.lowPriority {
                    guard isPolling && !Task.isCancelled else { return }
                    if await pollPID(pid) { pidCount += 1 }
                }
            }

            // Calculate actual polling rate
            let elapsed = Date().timeIntervalSince(cycleStart)
            if elapsed > 0 {
                let rate = Double(pidCount) / elapsed
                await MainActor.run { self.pollRate = rate }
            }

            // Adaptive delay: if cycle was fast, add a small delay to avoid hammering
            let targetCycleTime: TimeInterval = 0.25 // ~4 cycles/sec
            let remaining = targetCycleTime - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }
    }

    private func pollPID(_ pid: PIDDefinition) async -> Bool {
        guard let adapter else { return false }

        do {
            let bytes = try await adapter.sendPID(pid.command)
            let response = OBDResponse(pid: pid, rawBytes: bytes)

            await MainActor.run { [weak self] in
                self?.dataStore?.update(with: response)
            }

            // Successful response — decrease error pressure
            if errorCount > 0 {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.errorCount = max(0, self.errorCount - 1)
                }
            }

            return true
        } catch {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.errorCount += 1
                self.lastError = "\(pid.name): \(error.localizedDescription)"
            }

            // If too many errors, slow down polling
            if errorCount > 10 {
                pollInterval = min(pollInterval * 1.5, 2.0)
            }

            // If extreme errors, stop polling
            if errorCount > 50 {
                await MainActor.run { [weak self] in
                    self?.isPolling = false
                    self?.lastError = "Too many errors (\(self?.errorCount ?? 0)). Polling stopped. Check adapter connection."
                }
                return false
            }

            return false
        }
    }
}
