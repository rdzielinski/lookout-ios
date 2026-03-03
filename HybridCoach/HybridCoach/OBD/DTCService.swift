import Foundation

/// Reads and clears Diagnostic Trouble Codes via OBD-II Mode 03/04/07.
@MainActor
@Observable
final class DTCService {

    private(set) var storedCodes: [DiagnosticTroubleCode] = []
    private(set) var pendingCodes: [DiagnosticTroubleCode] = []
    private(set) var isReading = false
    private(set) var lastScanDate: Date?
    private(set) var errorMessage: String?

    // MARK: - Read Stored DTCs (Mode 03)

    /// Send OBD-II Mode 03 to read confirmed/stored trouble codes.
    func readStoredDTCs(adapter: OBDAdapter) async {
        isReading = true
        errorMessage = nil

        do {
            let bytes = try await adapter.sendPID("03")
            storedCodes = parseDTCBytes(bytes, isPending: false)
            lastScanDate = Date()
        } catch {
            errorMessage = "Failed to read stored codes: \(error.localizedDescription)"
            storedCodes = []
        }

        isReading = false
    }

    // MARK: - Read Pending DTCs (Mode 07)

    /// Send OBD-II Mode 07 to read pending (not yet confirmed) trouble codes.
    func readPendingDTCs(adapter: OBDAdapter) async {
        isReading = true
        errorMessage = nil

        do {
            let bytes = try await adapter.sendPID("07")
            pendingCodes = parseDTCBytes(bytes, isPending: true)
            lastScanDate = Date()
        } catch {
            errorMessage = "Failed to read pending codes: \(error.localizedDescription)"
            pendingCodes = []
        }

        isReading = false
    }

    // MARK: - Read All DTCs

    /// Convenience to read both stored and pending codes.
    func readAllDTCs(adapter: OBDAdapter) async {
        isReading = true
        errorMessage = nil

        do {
            let storedBytes = try await adapter.sendPID("03")
            storedCodes = parseDTCBytes(storedBytes, isPending: false)

            let pendingBytes = try await adapter.sendPID("07")
            pendingCodes = parseDTCBytes(pendingBytes, isPending: true)

            lastScanDate = Date()
        } catch {
            errorMessage = "Failed to read codes: \(error.localizedDescription)"
        }

        isReading = false
    }

    // MARK: - Clear DTCs (Mode 04)

    /// Send OBD-II Mode 04 to clear all stored trouble codes and reset MIL.
    /// ⚠️ This also resets readiness monitors.
    func clearDTCs(adapter: OBDAdapter) async {
        isReading = true
        errorMessage = nil

        do {
            _ = try await adapter.sendPID("04")
            storedCodes = []
            pendingCodes = []
            lastScanDate = Date()
        } catch {
            errorMessage = "Failed to clear codes: \(error.localizedDescription)"
        }

        isReading = false
    }

    // MARK: - Parsing

    /// Parse DTC byte pairs from a Mode 03/07 response.
    /// Response bytes arrive as pairs: [A1, B1, A2, B2, ...] where each pair is one DTC.
    private func parseDTCBytes(_ bytes: [UInt8], isPending: Bool) -> [DiagnosticTroubleCode] {
        var codes: [DiagnosticTroubleCode] = []

        // Process byte pairs
        var i = 0
        while i + 1 < bytes.count {
            let highByte = bytes[i]
            let lowByte = bytes[i + 1]
            i += 2

            // Skip padding (00 00)
            guard highByte != 0 || lowByte != 0 else { continue }

            if let codeString = DTCDecoder.decode(highByte: highByte, lowByte: lowByte) {
                let system = DiagnosticTroubleCode.DTCSystem(rawValue: String(codeString.prefix(1)))
                    ?? .powertrain

                let dtc = DiagnosticTroubleCode(
                    code: codeString,
                    system: system,
                    description: DTCLookupTable.description(for: codeString),
                    isPending: isPending
                )
                codes.append(dtc)
            }
        }

        return codes
    }
}
