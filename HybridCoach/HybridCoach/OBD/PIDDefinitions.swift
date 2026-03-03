import Foundation

struct PIDDefinition: Sendable {
    let mode: UInt8
    let pid: UInt8
    let name: String
    let unit: String
    let responseBytes: Int
    let formula: @Sendable ([UInt8]) -> Double
    let command: String

    var description: String { "\(name) (\(unit))" }
}

enum PIDCatalog {

    // MARK: - High Priority (every poll cycle)

    static let engineRPM = PIDDefinition(
        mode: 0x01, pid: 0x0C, name: "Engine RPM", unit: "rpm",
        responseBytes: 2,
        formula: { b in (Double(b[0]) * 256.0 + Double(b[1])) / 4.0 },
        command: "010C"
    )

    static let vehicleSpeed = PIDDefinition(
        mode: 0x01, pid: 0x0D, name: "Vehicle Speed", unit: "km/h",
        responseBytes: 1,
        formula: { b in Double(b[0]) },
        command: "010D"
    )

    static let mafRate = PIDDefinition(
        mode: 0x01, pid: 0x10, name: "MAF Rate", unit: "g/s",
        responseBytes: 2,
        formula: { b in (Double(b[0]) * 256.0 + Double(b[1])) / 100.0 },
        command: "0110"
    )

    static let throttlePosition = PIDDefinition(
        mode: 0x01, pid: 0x11, name: "Throttle Position", unit: "%",
        responseBytes: 1,
        formula: { b in Double(b[0]) * 100.0 / 255.0 },
        command: "0111"
    )

    // MARK: - Medium Priority (every 2nd cycle)

    static let engineLoad = PIDDefinition(
        mode: 0x01, pid: 0x04, name: "Engine Load", unit: "%",
        responseBytes: 1,
        formula: { b in Double(b[0]) * 100.0 / 255.0 },
        command: "0104"
    )

    static let acceleratorPedalPosition = PIDDefinition(
        mode: 0x01, pid: 0x49, name: "Accelerator Pedal", unit: "%",
        responseBytes: 1,
        formula: { b in Double(b[0]) * 100.0 / 255.0 },
        command: "0149"
    )

    // MARK: - Low Priority (every 5th cycle)

    static let coolantTemp = PIDDefinition(
        mode: 0x01, pid: 0x05, name: "Coolant Temp", unit: "C",
        responseBytes: 1,
        formula: { b in Double(b[0]) - 40.0 },
        command: "0105"
    )

    static let intakeAirTemp = PIDDefinition(
        mode: 0x01, pid: 0x0F, name: "Intake Air Temp", unit: "C",
        responseBytes: 1,
        formula: { b in Double(b[0]) - 40.0 },
        command: "010F"
    )

    static let ambientTemp = PIDDefinition(
        mode: 0x01, pid: 0x46, name: "Ambient Temp", unit: "C",
        responseBytes: 1,
        formula: { b in Double(b[0]) - 40.0 },
        command: "0146"
    )

    static let fuelLevel = PIDDefinition(
        mode: 0x01, pid: 0x2F, name: "Fuel Level", unit: "%",
        responseBytes: 1,
        formula: { b in Double(b[0]) * 100.0 / 255.0 },
        command: "012F"
    )

    static let barometricPressure = PIDDefinition(
        mode: 0x01, pid: 0x33, name: "Barometric Pressure", unit: "kPa",
        responseBytes: 1,
        formula: { b in Double(b[0]) },
        command: "0133"
    )

    // MARK: - Priority Groups

    static let highPriority: [PIDDefinition] = [
        engineRPM, vehicleSpeed, mafRate, throttlePosition
    ]

    static let mediumPriority: [PIDDefinition] = [
        engineLoad, acceleratorPedalPosition
    ]

    static let lowPriority: [PIDDefinition] = [
        coolantTemp, intakeAirTemp, ambientTemp,
        fuelLevel, barometricPressure
    ]

    static let all: [PIDDefinition] = highPriority + mediumPriority + lowPriority
}
