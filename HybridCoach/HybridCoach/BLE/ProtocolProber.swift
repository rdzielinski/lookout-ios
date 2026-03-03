import Foundation
@preconcurrency import CoreBluetooth

// MARK: - Probe Definition

struct ProbeDefinition {
    let label: String
    let category: ProbeResult.ProbeCategory
    let data: Data
    let timeout: TimeInterval

    init(label: String, category: ProbeResult.ProbeCategory, bytes: [UInt8], timeout: TimeInterval = 2.0) {
        self.label = label
        self.category = category
        self.data = Data(bytes)
        self.timeout = timeout
    }

    init(label: String, category: ProbeResult.ProbeCategory, ascii: String, timeout: TimeInterval = 2.0) {
        self.label = label
        self.category = category
        self.data = Data((ascii + "\r").utf8)
        self.timeout = timeout
    }
}

// MARK: - Protocol Prober

final class ProtocolProber: @unchecked Sendable {

    private let peripheral: CBPeripheral
    private let writeChar: CBCharacteristic
    private let notifyChar: CBCharacteristic
    private let store: ProtocolAnalyzerStore

    private var responseBuffer = Data()
    private var responseContinuation: CheckedContinuation<Data, Error>?
    private var dataObserver: NSObjectProtocol?

    init(peripheral: CBPeripheral,
         writeCharacteristic: CBCharacteristic,
         notifyCharacteristic: CBCharacteristic,
         store: ProtocolAnalyzerStore) {
        self.peripheral = peripheral
        self.writeChar = writeCharacteristic
        self.notifyChar = notifyCharacteristic
        self.store = store

        dataObserver = NotificationCenter.default.addObserver(
            forName: .init("OBDDataReceived"), object: nil, queue: .main
        ) { [weak self] notification in
            if let data = notification.userInfo?["data"] as? Data {
                self?.didReceiveData(data)
            }
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Run all probes sequentially, updating the store with progress.
    func runAllProbes() async {
        await MainActor.run { [store] in
            store.isProbing = true
            store.probeProgress = 0
            store.probeResults.removeAll()
            store.detectedPatterns.removeAll()
        }

        let allProbes = Self.probeCatalog
        let total = Double(allProbes.count)

        for (index, probe) in allProbes.enumerated() {
            // Check cancellation
            let shouldContinue = await MainActor.run { store.isProbing }
            guard shouldContinue else { break }

            await MainActor.run { [store] in
                store.probeStatusMessage = "[\(index + 1)/\(Int(total))] \(probe.label)"
            }

            _ = await sendProbeAndLog(probe)

            await MainActor.run { [store] in
                store.probeProgress = Double(index + 1) / total
            }

            // Small delay between probes to let the device settle
            try? await Task.sleep(for: .milliseconds(250))
        }

        await analyzePatterns()

        await MainActor.run { [store] in
            store.isProbing = false
            store.probeStatusMessage = "Complete — \(store.probeResults.count) probes run"
        }
    }

    /// Send a single probe, log traffic, return result.
    @discardableResult
    func sendProbeAndLog(_ probe: ProbeDefinition) async -> ProbeResult {
        let startTime = Date()

        await MainActor.run { [store] in
            store.logTraffic(direction: .sent, label: probe.label, data: probe.data)
        }

        do {
            let response = try await sendRawBytes(probe.data, timeout: probe.timeout)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            await MainActor.run { [store] in
                store.logTraffic(direction: .received, label: "Response: \(probe.label)", data: response)
            }

            let status: ProbeResult.ProbeStatus = (response == probe.data) ? .echo : .success

            let result = ProbeResult(
                timestamp: Date(),
                label: probe.label,
                category: probe.category,
                sentBytes: probe.data,
                receivedBytes: response,
                status: status,
                durationMs: durationMs
            )

            await MainActor.run { [store] in store.addProbeResult(result) }
            return result

        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let result = ProbeResult(
                timestamp: Date(),
                label: probe.label,
                category: probe.category,
                sentBytes: probe.data,
                receivedBytes: nil,
                status: .timeout,
                durationMs: durationMs
            )
            await MainActor.run { [store] in store.addProbeResult(result) }
            return result
        }
    }

    /// Send raw bytes from the interactive console. Returns response data or nil on timeout.
    func sendRawAndLog(data: Data, label: String) async -> Data? {
        let probe = ProbeDefinition(label: label, category: .proprietaryFramed, bytes: Array(data), timeout: 3.0)
        let result = await sendProbeAndLog(probe)
        return result.receivedBytes
    }

    /// Stop an in-progress probe run.
    func stopProbing() {
        store.isProbing = false
    }

    // MARK: - BLE Send/Receive

    private func sendRawBytes(_ data: Data, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: OBDAdapterError.notConnected)
                    return
                }

                self.responseBuffer = Data()
                self.responseContinuation = continuation

                let writeType: CBCharacteristicWriteType =
                    self.writeChar.properties.contains(.writeWithoutResponse)
                        ? .withoutResponse : .withResponse

                self.peripheral.writeValue(data, for: self.writeChar, type: writeType)

                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.responseContinuation != nil else { return }
                    let buffered = self.responseBuffer
                    self.responseBuffer = Data()
                    if buffered.isEmpty {
                        self.responseContinuation?.resume(throwing: OBDAdapterError.timeout)
                    } else {
                        self.responseContinuation?.resume(returning: buffered)
                    }
                    self.responseContinuation = nil
                }
            }
        }
    }

    private func didReceiveData(_ data: Data) {
        responseBuffer.append(data)

        // If we have a pending continuation, check for common terminators
        guard responseContinuation != nil else {
            // Unsolicited data — log it
            Task { @MainActor [store] in
                store.logTraffic(direction: .unsolicited, label: "Unsolicited", data: data)
            }
            return
        }

        // Check for ELM327-style ">" prompt terminator
        if let str = String(data: responseBuffer, encoding: .ascii), str.contains(">") {
            let fullResponse = responseBuffer
            responseBuffer = Data()
            responseContinuation?.resume(returning: fullResponse)
            responseContinuation = nil
            return
        }

        // For binary protocols: if we got data and 300ms passes with no more, the timeout
        // handler will return whatever we have. This is intentional — binary protocols
        // don't have a known terminator, so we rely on the timeout to collect the full response.
    }

    // MARK: - Pattern Analysis

    private func analyzePatterns() async {
        var patterns: [String] = []

        let results = await MainActor.run { store.probeResults }

        let responded = results.filter { $0.status == .success }
        let echoed = results.filter { $0.status == .echo }
        let timedOut = results.filter { $0.status == .timeout }

        // Overall responsiveness
        if responded.isEmpty && echoed.isEmpty {
            patterns.append("No response to any probe — device may need a wake-up sequence or different characteristic pair")
        }

        // ELM327 detection
        let elm327Responses = responded.filter { $0.category == .elm327 }
        if !elm327Responses.isEmpty {
            let responseTexts = elm327Responses.compactMap { r in
                r.receivedBytes.flatMap { String(data: $0, encoding: .ascii) }
            }
            if responseTexts.contains(where: { $0.contains("ELM") }) {
                patterns.append("Device contains ELM327 chip — responds with ELM identifier")
            } else if responseTexts.contains(where: { $0.contains("OK") || $0.contains(">") }) {
                patterns.append("Device responds to ELM327 AT commands (may be ELM327-compatible)")
            } else {
                patterns.append("Device responds to ASCII commands but not standard ELM327")
            }
        }

        // STN chip detection
        let stnResponses = responded.filter { $0.category == .stnChip }
        if !stnResponses.isEmpty {
            patterns.append("Device responds to STN chip commands (OBDLink-compatible)")
        }

        // Echo detection
        if echoed.count > results.count / 2 {
            patterns.append("Device echoes back sent data — may need echo-off command first")
        }

        // CAN detection
        let canResponses = responded.filter { $0.category == .canBus }
        if !canResponses.isEmpty {
            patterns.append("Device responds to raw CAN frames")
        }

        // Binary protocol detection
        let binaryResponses = responded.filter {
            $0.category == .proprietaryFramed || $0.category == .singleByte
        }
        if !binaryResponses.isEmpty {
            patterns.append("Device responds to binary protocol probes (\(binaryResponses.count) responses)")

            // Check for common response prefix
            let prefixes = binaryResponses.compactMap { $0.receivedBytes?.first }
            let prefixCounts = Dictionary(grouping: prefixes, by: { $0 }).mapValues(\.count)
            if let (commonByte, count) = prefixCounts.max(by: { $0.value < $1.value }), count >= 2 {
                patterns.append("Common response prefix byte: 0x\(String(format: "%02X", commonByte)) (seen \(count) times)")
            }

            // Check for consistent response length
            let lengths = binaryResponses.compactMap { $0.receivedBytes?.count }
            let lengthCounts = Dictionary(grouping: lengths, by: { $0 }).mapValues(\.count)
            if let (commonLen, count) = lengthCounts.max(by: { $0.value < $1.value }), count >= 2 {
                patterns.append("Common response length: \(commonLen) bytes (seen \(count) times)")
            }
        }

        // Summary stats
        patterns.append("Summary: \(responded.count) responses, \(echoed.count) echoes, \(timedOut.count) timeouts out of \(results.count) probes")

        await MainActor.run { [store] in
            store.detectedPatterns = patterns
        }
    }

    // MARK: - Probe Catalog

    static let probeCatalog: [ProbeDefinition] = {
        var probes: [ProbeDefinition] = []

        // ── ELM327 AT Commands ──────────────────────────────────────

        probes.append(ProbeDefinition(label: "ATZ (Reset)", category: .elm327, ascii: "ATZ", timeout: 3.0))
        probes.append(ProbeDefinition(label: "ATI (Identify)", category: .elm327, ascii: "ATI"))
        probes.append(ProbeDefinition(label: "ATE0 (Echo Off)", category: .elm327, ascii: "ATE0"))
        probes.append(ProbeDefinition(label: "ATE1 (Echo On)", category: .elm327, ascii: "ATE1"))
        probes.append(ProbeDefinition(label: "ATL0 (Linefeeds Off)", category: .elm327, ascii: "ATL0"))
        probes.append(ProbeDefinition(label: "ATS0 (Spaces Off)", category: .elm327, ascii: "ATS0"))
        probes.append(ProbeDefinition(label: "ATH0 (Headers Off)", category: .elm327, ascii: "ATH0"))
        probes.append(ProbeDefinition(label: "ATH1 (Headers On)", category: .elm327, ascii: "ATH1"))
        probes.append(ProbeDefinition(label: "ATSP0 (Auto Protocol)", category: .elm327, ascii: "ATSP0"))
        probes.append(ProbeDefinition(label: "ATSP6 (CAN 11-bit 500k)", category: .elm327, ascii: "ATSP6"))
        probes.append(ProbeDefinition(label: "ATDP (Describe Protocol)", category: .elm327, ascii: "ATDP"))
        probes.append(ProbeDefinition(label: "ATRV (Read Voltage)", category: .elm327, ascii: "ATRV"))
        probes.append(ProbeDefinition(label: "AT@1 (Device Description)", category: .elm327, ascii: "AT@1"))
        probes.append(ProbeDefinition(label: "0100 (Supported PIDs)", category: .elm327, ascii: "0100", timeout: 5.0))
        probes.append(ProbeDefinition(label: "010C (Engine RPM)", category: .elm327, ascii: "010C", timeout: 3.0))

        // ── STN Chip Identification ─────────────────────────────────

        probes.append(ProbeDefinition(label: "STDI (STN Device ID)", category: .stnChip, ascii: "STDI"))
        probes.append(ProbeDefinition(label: "STI (STN Info)", category: .stnChip, ascii: "STI"))
        probes.append(ProbeDefinition(label: "STFAC (STN Factory)", category: .stnChip, ascii: "STFAC"))

        // ── Raw CAN Bus Frames ──────────────────────────────────────

        // CAN 11-bit: ID=7DF (broadcast), Mode 01 PID 00
        probes.append(ProbeDefinition(label: "CAN 7DF: 0100 (Broadcast PIDs)", category: .canBus,
            bytes: [0x00, 0x00, 0x07, 0xDF, 0x02, 0x01, 0x00]))
        // CAN 11-bit: ID=7E0 (ECU 1), Mode 01 PID 0C (RPM)
        probes.append(ProbeDefinition(label: "CAN 7E0: 010C (ECU1 RPM)", category: .canBus,
            bytes: [0x00, 0x00, 0x07, 0xE0, 0x02, 0x01, 0x0C]))
        // CAN 29-bit: ID=18DB33F1, Mode 01 PID 00
        probes.append(ProbeDefinition(label: "CAN 29-bit: 0100", category: .canBus,
            bytes: [0x18, 0xDB, 0x33, 0xF1, 0x02, 0x01, 0x00]))
        // Minimal CAN-TP single frame
        probes.append(ProbeDefinition(label: "CAN-TP Single Frame: 0100", category: .canBus,
            bytes: [0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))

        // ── ISO 14230 (KWP2000) ─────────────────────────────────────

        probes.append(ProbeDefinition(label: "KWP2000 StartDiag", category: .iso14230,
            bytes: [0x68, 0x6A, 0xF1, 0x10, 0x89, 0xCC]))
        probes.append(ProbeDefinition(label: "KWP2000 TesterPresent", category: .iso14230,
            bytes: [0x68, 0x6A, 0xF1, 0x3E, 0xC3]))
        probes.append(ProbeDefinition(label: "KWP2000 ReadECUID", category: .iso14230,
            bytes: [0x68, 0x6A, 0xF1, 0x1A, 0x80, 0x4D]))

        // ── ISO 9141 ────────────────────────────────────────────────

        probes.append(ProbeDefinition(label: "ISO 9141 Init (5-baud)", category: .iso9141,
            bytes: [0x55, 0x08, 0x22]))
        probes.append(ProbeDefinition(label: "ISO 9141 Slow Init", category: .iso9141,
            bytes: [0x33, 0x00]))

        // ── J1850 ───────────────────────────────────────────────────

        probes.append(ProbeDefinition(label: "J1850 VPW: 0100", category: .j1850,
            bytes: [0x48, 0x6B, 0x10, 0x01, 0x00, 0xC4]))
        probes.append(ProbeDefinition(label: "J1850 PWM: 0100", category: .j1850,
            bytes: [0x28, 0x6B, 0x10, 0x01, 0x00, 0xA4]))

        // ── Proprietary Framed Patterns ─────────────────────────────

        // AA header with XOR checksum
        probes.append(ProbeDefinition(label: "AA-header + XOR checksum", category: .proprietaryFramed,
            bytes: [0xAA, 0x00, 0x01, 0x00, 0xAB]))
        // 55-55-AA sync pattern
        probes.append(ProbeDefinition(label: "55-55-AA sync", category: .proprietaryFramed,
            bytes: [0x55, 0x55, 0xAA, 0x01, 0x00]))
        // STX/ETX framing (0x02 / 0x03)
        probes.append(ProbeDefinition(label: "STX/ETX Frame", category: .proprietaryFramed,
            bytes: [0x02, 0x01, 0x00, 0x03]))
        // HDLC-like 0x7E framing
        probes.append(ProbeDefinition(label: "HDLC 7E Frame", category: .proprietaryFramed,
            bytes: [0x7E, 0x03, 0x01, 0x00, 0x04, 0x7E]))
        // Length-prefixed with additive checksum
        probes.append(ProbeDefinition(label: "Length-Prefix + Sum Check", category: .proprietaryFramed,
            bytes: [0x02, 0x00, 0x01, 0x01, 0x04]))
        // FE/FF delimiters
        probes.append(ProbeDefinition(label: "FE/FF Delimiters", category: .proprietaryFramed,
            bytes: [0xFE, 0x04, 0x01, 0x00, 0x00, 0xFF]))
        // AA55 sync with length byte
        probes.append(ProbeDefinition(label: "AA55 Sync + Length", category: .proprietaryFramed,
            bytes: [0xAA, 0x55, 0x02, 0x01, 0x00, 0x03]))
        // Common Chinese OBD: AT prefix as binary
        probes.append(ProbeDefinition(label: "Binary AT-like", category: .proprietaryFramed,
            bytes: [0x41, 0x54, 0x5A, 0x0D]))  // "ATZ\r" as raw bytes

        // ── Single Byte Discovery ───────────────────────────────────
        // Send individual bytes to see what triggers a response

        probes.append(ProbeDefinition(label: "Single 0x00", category: .singleByte, bytes: [0x00], timeout: 1.5))
        probes.append(ProbeDefinition(label: "Single 0x01", category: .singleByte, bytes: [0x01], timeout: 1.5))
        probes.append(ProbeDefinition(label: "Single 0x55", category: .singleByte, bytes: [0x55], timeout: 1.5))
        probes.append(ProbeDefinition(label: "Single 0xAA", category: .singleByte, bytes: [0xAA], timeout: 1.5))
        probes.append(ProbeDefinition(label: "Single 0xFF", category: .singleByte, bytes: [0xFF], timeout: 1.5))
        probes.append(ProbeDefinition(label: "Single CR (0x0D)", category: .singleByte, bytes: [0x0D], timeout: 1.5))

        return probes
    }()
}
