import Foundation
@preconcurrency import CoreBluetooth

// MARK: - Traffic Log Entry

struct TrafficLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let label: String
    let rawBytes: Data
    let hexString: String
    let asciiString: String

    enum Direction: String {
        case sent = "TX"
        case received = "RX"
        case unsolicited = "RX*"
    }
}

// MARK: - Probe Result

struct ProbeResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let label: String
    let category: ProbeCategory
    let sentBytes: Data
    let receivedBytes: Data?
    let status: ProbeStatus
    let durationMs: Int

    enum ProbeStatus: String {
        case success = "Response"
        case timeout = "Timeout"
        case error = "Error"
        case echo = "Echo"
    }

    enum ProbeCategory: String, CaseIterable {
        case elm327 = "ELM327"
        case stnChip = "STN Chip"
        case canBus = "CAN Bus"
        case iso14230 = "ISO 14230"
        case iso9141 = "ISO 9141"
        case j1850 = "J1850"
        case proprietaryFramed = "Proprietary"
        case singleByte = "Single Byte"
    }
}

// MARK: - GATT Characteristic Info

struct GATTCharacteristicInfo: Identifiable {
    let id = UUID()
    let serviceUUID: CBUUID
    let serviceName: String?
    let characteristicUUID: CBUUID
    let characteristicName: String?
    let properties: String
    let readValue: Data?
    let readValueString: String?
}

// MARK: - Device Info

struct DeviceInfo {
    var manufacturerName: String?
    var modelNumber: String?
    var serialNumber: String?
    var firmwareRevision: String?
    var hardwareRevision: String?
    var softwareRevision: String?
    var peripheralName: String?
    var peripheralUUID: UUID?

    var isEmpty: Bool {
        manufacturerName == nil && modelNumber == nil && serialNumber == nil &&
        firmwareRevision == nil && hardwareRevision == nil && softwareRevision == nil
    }
}

// MARK: - Protocol Analyzer Store

@Observable
final class ProtocolAnalyzerStore {

    // Device information
    var deviceInfo = DeviceInfo()

    // Full GATT tree with values
    var gattCharacteristics: [GATTCharacteristicInfo] = []

    // Traffic log (all sent/received bytes)
    var trafficLog: [TrafficLogEntry] = []

    // Probe results
    var probeResults: [ProbeResult] = []

    // State
    var isProbing = false
    var probeProgress: Double = 0
    var probeStatusMessage: String = ""

    // Detected patterns
    var detectedPatterns: [String] = []

    // Whether the analyzer has been activated
    var isActive = false

    // MARK: - API

    func logTraffic(direction: TrafficLogEntry.Direction, label: String, data: Data) {
        let entry = TrafficLogEntry(
            timestamp: Date(),
            direction: direction,
            label: label,
            rawBytes: data,
            hexString: data.map { String(format: "%02X", $0) }.joined(separator: " "),
            asciiString: String(data.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        )
        trafficLog.append(entry)

        // Cap at 10,000 entries
        if trafficLog.count > 10_000 {
            trafficLog.removeFirst(trafficLog.count - 10_000)
        }
    }

    func addProbeResult(_ result: ProbeResult) {
        probeResults.append(result)
    }

    func clearAll() {
        trafficLog.removeAll()
        probeResults.removeAll()
        gattCharacteristics.removeAll()
        detectedPatterns.removeAll()
        deviceInfo = DeviceInfo()
    }

    func clearTrafficLog() {
        trafficLog.removeAll()
    }

    // MARK: - Export

    func exportReport() -> String {
        var lines: [String] = []
        lines.append("=== HybridCoach Protocol Analysis Report ===")
        lines.append("Date: \(Date())")
        lines.append("")

        // Device Info
        lines.append("--- Device Information ---")
        lines.append("Name: \(deviceInfo.peripheralName ?? "Unknown")")
        lines.append("UUID: \(deviceInfo.peripheralUUID?.uuidString ?? "Unknown")")
        lines.append("Manufacturer: \(deviceInfo.manufacturerName ?? "N/A")")
        lines.append("Model: \(deviceInfo.modelNumber ?? "N/A")")
        lines.append("Serial: \(deviceInfo.serialNumber ?? "N/A")")
        lines.append("Firmware: \(deviceInfo.firmwareRevision ?? "N/A")")
        lines.append("Hardware: \(deviceInfo.hardwareRevision ?? "N/A")")
        lines.append("Software: \(deviceInfo.softwareRevision ?? "N/A")")
        lines.append("")

        // GATT Tree
        lines.append("--- GATT Services ---")
        let grouped = Dictionary(grouping: gattCharacteristics) { $0.serviceUUID.uuidString }
        for (serviceUUID, chars) in grouped.sorted(by: { $0.key < $1.key }) {
            let svcName = chars.first?.serviceName ?? serviceUUID
            lines.append("Service: \(svcName) (\(serviceUUID))")
            for c in chars {
                let name = c.characteristicName ?? c.characteristicUUID.uuidString
                lines.append("  Char: \(name) [\(c.properties)]")
                if let hex = c.readValue?.map({ String(format: "%02X", $0) }).joined(separator: " ") {
                    lines.append("    Value (hex): \(hex)")
                }
                if let str = c.readValueString {
                    lines.append("    Value (str): \(str)")
                }
            }
        }
        lines.append("")

        // Probe Results
        lines.append("--- Probe Results (\(probeResults.count) probes) ---")
        for result in probeResults {
            let sentHex = result.sentBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let recvHex = result.receivedBytes?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "—"
            lines.append("[\(result.category.rawValue)] \(result.label): \(result.status.rawValue) (\(result.durationMs)ms)")
            lines.append("  Sent: \(sentHex)")
            lines.append("  Recv: \(recvHex)")
        }
        lines.append("")

        // Patterns
        if !detectedPatterns.isEmpty {
            lines.append("--- Detected Patterns ---")
            for pattern in detectedPatterns {
                lines.append("  - \(pattern)")
            }
            lines.append("")
        }

        // Traffic Log
        lines.append("--- Traffic Log (\(trafficLog.count) entries) ---")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for entry in trafficLog {
            lines.append("[\(formatter.string(from: entry.timestamp))] \(entry.direction.rawValue)  \(entry.hexString)  | \(entry.asciiString)")
        }

        return lines.joined(separator: "\n")
    }
}
