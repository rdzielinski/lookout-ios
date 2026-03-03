import Foundation

struct OBDResponse {
    let pid: PIDDefinition
    let rawBytes: [UInt8]
    let value: Double
    let timestamp: Date

    init(pid: PIDDefinition, rawBytes: [UInt8]) {
        self.pid = pid
        self.rawBytes = rawBytes
        self.timestamp = Date()

        // Safety net: ensure we have enough bytes for the formula.
        // Formulas access b[0], b[1], etc. — passing an empty or too-short
        // array would crash with "Index out of range".
        if rawBytes.count >= pid.responseBytes && pid.responseBytes > 0 {
            self.value = pid.formula(Array(rawBytes.prefix(pid.responseBytes)))
        } else {
            // Not enough bytes — return 0 rather than crashing.
            // The upstream sendPID should normally throw .noData before we get here,
            // but this guards against any edge case.
            self.value = 0
        }
    }
}
