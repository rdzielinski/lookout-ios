import Foundation

/// Polls OBD-II PIDs on an adaptive timer and feeds parsed responses into the DrivingDataStore.
///
/// Three priority tiers:
/// - High: RPM, Speed, MAF, Throttle — every cycle
/// - Medium: Engine Load, Accel Pedal — every 2nd cycle
/// - Low: Coolant/Intake/Ambient temps, Fuel Level, Baro — every 5th cycle
@MainActor
@Observable
final class OBDService {

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
    private var pollInterval: TimeInterval = 0.25

    /// Per-PID consecutive error counts. When a PID fails too many times in a row,
    /// it is disabled rather than poisoning the global error counter.
    private var pidErrorCounts: [String: Int] = [:]

    /// PIDs disabled due to repeated failures (likely unsupported by vehicle).
    private(set) var disabledPIDs: Set<String> = []

    /// Max consecutive per-PID errors before disabling that PID.
    private let maxPIDErrors = 5

    // MARK: - Public API

    func start(adapter: OBDAdapter, dataStore: DrivingDataStore) {
        // Cancel any previous polling task to prevent leaked background Tasks
        pollingTask?.cancel()
        pollingTask = nil

        self.adapter = adapter
        self.dataStore = dataStore
        self.errorCount = 0
        self.lastError = nil
        self.cycleCount = 0
        self.pidErrorCounts = [:]
        self.disabledPIDs = []
        self.pollInterval = 0.25

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
                pollRate = Double(pidCount) / elapsed
            }

            // Use the adaptive pollInterval (not a hardcoded value)
            let remaining = pollInterval - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }
    }

    private func pollPID(_ pid: PIDDefinition) async -> Bool {
        guard let adapter else { return false }

        // Skip PIDs that have been disabled due to repeated failures
        if disabledPIDs.contains(pid.command) {
            return false
        }

        do {
            let bytes = try await adapter.sendPID(pid.command)
            let response = OBDResponse(pid: pid, rawBytes: bytes)

            dataStore?.update(with: response)

            // Successful response — clear per-PID error count and decrease global pressure
            pidErrorCounts[pid.command] = 0
            if errorCount > 0 {
                errorCount = max(0, errorCount - 1)
            }

            // Speed up polling on sustained success
            if errorCount == 0 && pollInterval > 0.25 {
                pollInterval = max(0.25, pollInterval * 0.9)
            }

            return true
        } catch {
            // Track per-PID errors separately from global errors
            let pidErrors = (pidErrorCounts[pid.command] ?? 0) + 1
            pidErrorCounts[pid.command] = pidErrors

            if pidErrors >= maxPIDErrors {
                // This PID is likely unsupported — disable it instead of killing all polling
                disabledPIDs.insert(pid.command)
                lastError = "\(pid.name): disabled (unsupported)"
                print("OBDService: Disabled PID \(pid.command) (\(pid.name)) after \(pidErrors) consecutive failures")
                return false
            }

            errorCount += 1
            lastError = "\(pid.name): \(error.localizedDescription)"

            // Slow down polling on sustained errors
            if errorCount > 10 {
                pollInterval = min(pollInterval * 1.5, 2.0)
            }

            // Only stop on extreme global errors (not per-PID)
            if errorCount > 50 {
                isPolling = false
                lastError = "Too many errors (\(errorCount)). Polling stopped. Check adapter connection."
                return false
            }

            return false
        }
    }
}
