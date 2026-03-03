import Foundation
import CoreBluetooth

/// Standard ELM327 BLE adapter — handles AT commands and PID requests
/// over a write/notify GATT characteristic pair.
final class ELM327Adapter: OBDAdapter, @unchecked Sendable {

    private(set) var state: AdapterState = .disconnected
    let adapterType: AdapterType = .elm327

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var responseBuffer = Data()
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var dataObserver: NSObjectProtocol?

    // MARK: - OBDAdapter Protocol

    func configure(peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic, notifyCharacteristic: CBCharacteristic) {
        self.peripheral = peripheral
        self.writeChar = writeCharacteristic
        self.notifyChar = notifyCharacteristic
        state = .connectedToAdapter

        // Listen for BLE data notifications
        dataObserver = NotificationCenter.default.addObserver(
            forName: .init("OBDDataReceived"), object: nil, queue: .main
        ) { [weak self] notification in
            if let data = notification.userInfo?["data"] as? Data {
                self?.didReceiveData(data)
            }
        }
    }

    /// Whether ATS0 succeeded — if not, responses will contain spaces (handled by parser).
    private(set) var spacesOff = false

    func initialize() async throws {
        state = .initializing

        // ELM327 initialization sequence.
        // Some cheap clones (e.g. AutoPhix 3210 "ELM327 v1.5") don't support all AT commands.
        // We send required commands first, then optional ones that may return "?".

        // Required: Reset
        let resetResponse = try await sendCommand("ATZ", timeout: 2.0)
        print("ELM327: ATZ → \(resetResponse)")

        // Required: Echo off (crucial for clean response parsing)
        let echoResponse = try await sendCommand("ATE0", timeout: 1.0)
        if !echoResponse.contains("OK") {
            print("ELM327: ATE0 unexpected → \(echoResponse)")
        }

        // Required: Linefeeds off
        let lfResponse = try await sendCommand("ATL0", timeout: 1.0)
        if !lfResponse.contains("OK") {
            print("ELM327: ATL0 unexpected → \(lfResponse)")
        }

        // Optional: Spaces off — cheap clones may not support this (returns "?").
        // If it fails, responses will contain spaces which the parser handles fine.
        let spacesResponse = try await sendCommand("ATS0", timeout: 1.0)
        spacesOff = spacesResponse.contains("OK")
        if !spacesOff {
            print("ELM327: ATS0 not supported (responses will contain spaces) — this is OK")
        }

        // Required: Headers off
        let headersResponse = try await sendCommand("ATH0", timeout: 1.0)
        if !headersResponse.contains("OK") {
            print("ELM327: ATH0 unexpected → \(headersResponse)")
        }

        // Required: Set protocol to auto-detect. Using ATSP0 (auto) instead of ATSP6 (CAN 500k only)
        // because auto-detect works better across different vehicles and cheap clones.
        let protoResponse = try await sendCommand("ATSP0", timeout: 1.0)
        if !protoResponse.contains("OK") {
            print("ELM327: ATSP0 unexpected → \(protoResponse)")
        }

        // Test PID (supported PIDs) — non-fatal if vehicle ignition is off.
        // "SEARCHING..." followed by timeout or "UNABLE TO CONNECT" is normal when ignition is off.
        do {
            let testResponse = try await sendCommand("0100", timeout: 5.0)
            if testResponse.contains("41 00") || testResponse.contains("4100") {
                print("ELM327: Vehicle ECU responding — ready for live data")
                state = .ready
            } else if testResponse.contains("UNABLE TO CONNECT") || testResponse.contains("SEARCHING") ||
                      testResponse.contains("NO DATA") || testResponse.contains("ERROR") || testResponse.contains("?") {
                // Adapter works, but vehicle isn't responding — ignition likely off
                print("ELM327: Adapter OK but vehicle not responding (ignition off?): \(testResponse)")
                state = .ready  // Adapter itself is fine — polling will retry when vehicle is on
            } else {
                print("ELM327: Unexpected 0100 response: \(testResponse)")
                state = .ready  // Still mark ready — let OBDService handle retries
            }
        } catch OBDAdapterError.timeout {
            // Timeout on 0100 is common when ignition is off — adapter is still functional
            print("ELM327: 0100 timed out (vehicle ignition likely off) — adapter ready, will retry when driving")
            state = .ready
        }
    }

    func sendPID(_ pid: String) async throws -> [UInt8] {
        let response = try await sendCommand(pid, timeout: BLEConstants.commandTimeout)

        // Check for common non-data responses before parsing
        if response.contains("NO DATA") || response.contains("UNABLE TO CONNECT") ||
           response.contains("ERROR") || response.contains("?") {
            throw OBDAdapterError.noData
        }

        let bytes = parseOBDResponse(response, expectedPrefix: responsePrefix(for: pid))

        guard !bytes.isEmpty else {
            throw OBDAdapterError.noData
        }

        return bytes
    }

    func didReceiveData(_ data: Data) {
        responseBuffer.append(data)

        // ELM327 terminates responses with '>' prompt
        if let str = String(data: responseBuffer, encoding: .ascii), str.contains(">") {
            let fullResponse = String(data: responseBuffer, encoding: .ascii) ?? ""
            responseBuffer = Data()
            responseContinuation?.resume(returning: fullResponse.trimmingCharacters(in: .whitespacesAndNewlines))
            responseContinuation = nil
        }
    }

    func disconnect() {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        state = .disconnected
    }

    // MARK: - Private

    private func sendCommand(_ command: String, timeout: TimeInterval) async throws -> String {
        guard peripheral != nil, writeChar != nil else {
            throw OBDAdapterError.notConnected
        }

        let commandData = Data((command + "\r").utf8)

        return try await withCheckedThrowingContinuation { continuation in
            // All BLE interactions and shared state access must happen on the main queue
            // (CBCentralManager was created with queue: .main)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let peripheral = self.peripheral,
                      let writeChar = self.writeChar else {
                    continuation.resume(throwing: OBDAdapterError.notConnected)
                    return
                }

                self.responseBuffer = Data()
                self.responseContinuation = continuation

                let writeType: CBCharacteristicWriteType =
                    writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

                peripheral.writeValue(commandData, for: writeChar, type: writeType)

                // Timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.responseContinuation != nil else { return }
                    let partial = String(data: self.responseBuffer, encoding: .ascii) ?? ""
                    self.responseBuffer = Data()
                    if partial.isEmpty {
                        self.responseContinuation?.resume(throwing: OBDAdapterError.timeout)
                    } else {
                        self.responseContinuation?.resume(returning: partial)
                    }
                    self.responseContinuation = nil
                }
            }
        }
    }

    /// Convert hex PID like "010C" to expected response prefix "410C"
    private func responsePrefix(for pid: String) -> String {
        guard pid.count >= 4 else { return "" }
        let mode = pid.prefix(2)
        let pidCode = pid.suffix(from: pid.index(pid.startIndex, offsetBy: 2))
        // Response mode = request mode + 0x40
        if let modeNum = UInt8(mode, radix: 16) {
            return String(format: "%02X", modeNum + 0x40) + pidCode
        }
        return ""
    }

    /// Parse raw ELM327 ASCII response into byte array.
    ///
    /// Multi-ECU vehicles (like RAV4 Hybrid) return multiple response lines separated by \r,
    /// one per ECU. We take the FIRST line containing the expected prefix (e.g. "410C" for RPM).
    ///
    /// Example raw response (3 ECUs, spaces on, headers off):
    ///   "SEARCHING...\r41 0C 14 5C \r41 0C 14 00 \r41 0C 14 00 \r\r>"
    ///
    /// Example with headers on (probe mode):
    ///   "07 E8 04 41 0C 14 5C 00 00 00 \r07 EA 04 41 0C 14 00 00 00 00 \r\r>"
    private func parseOBDResponse(_ response: String, expectedPrefix: String) -> [UInt8] {
        // Split into individual ECU response lines (\r separates them in ELM327 protocol)
        let lines = response
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: "\r")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Find the first line that contains the expected response prefix
        for line in lines {
            let cleaned = line.replacingOccurrences(of: " ", with: "")
            guard let range = cleaned.range(of: expectedPrefix) else { continue }

            // Skip status messages like "SEARCHING...", "UNABLE TO CONNECT"
            if line.contains("SEARCHING") || line.contains("UNABLE") || line.contains("NO DATA") {
                continue
            }

            let dataHex = String(cleaned[range.upperBound...])

            // Convert hex pairs to bytes
            var bytes: [UInt8] = []
            var idx = dataHex.startIndex
            while idx < dataHex.endIndex {
                let nextIdx = dataHex.index(idx, offsetBy: 2, limitedBy: dataHex.endIndex) ?? dataHex.endIndex
                let hexPair = String(dataHex[idx..<nextIdx])
                if let byte = UInt8(hexPair, radix: 16) {
                    bytes.append(byte)
                } else {
                    break  // Stop at first non-hex character
                }
                idx = nextIdx
            }

            if !bytes.isEmpty {
                return bytes
            }
        }

        return []
    }
}
