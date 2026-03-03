import Foundation

/// A single Diagnostic Trouble Code read from the vehicle ECU.
struct DiagnosticTroubleCode: Identifiable, Hashable {
    let id = UUID()
    let code: String          // e.g., "P0301"
    let system: DTCSystem
    let description: String
    let isPending: Bool

    enum DTCSystem: String, CaseIterable {
        case powertrain = "P"
        case body = "B"
        case chassis = "C"
        case network = "U"

        var displayName: String {
            switch self {
            case .powertrain: "Powertrain"
            case .body: "Body"
            case .chassis: "Chassis"
            case .network: "Network"
            }
        }

        var color: String {
            switch self {
            case .powertrain: "red"
            case .body: "purple"
            case .chassis: "orange"
            case .network: "blue"
            }
        }
    }
}

// MARK: - DTC Byte Decoding

enum DTCDecoder {
    /// Decode a pair of raw bytes into a DTC code string.
    /// Format: first byte high nibble bits 7-6 = system, bits 5-4 = first digit,
    ///         first byte low nibble = second digit, second byte = third & fourth digits.
    static func decode(highByte: UInt8, lowByte: UInt8) -> String? {
        // 0x0000 means no code
        guard highByte != 0 || lowByte != 0 else { return nil }

        let systemIndex = (highByte >> 6) & 0x03
        let systemLetter: String
        switch systemIndex {
        case 0: systemLetter = "P"
        case 1: systemLetter = "C"
        case 2: systemLetter = "B"
        case 3: systemLetter = "U"
        default: systemLetter = "P"
        }

        let digit1 = (highByte >> 4) & 0x03
        let digit2 = highByte & 0x0F
        let digit3 = (lowByte >> 4) & 0x0F
        let digit4 = lowByte & 0x0F

        return String(format: "%@%01X%01X%01X%01X", systemLetter, digit1, digit2, digit3, digit4)
    }
}

// MARK: - Common Toyota / RAV4 DTC Lookup

enum DTCLookupTable {
    static func description(for code: String) -> String {
        return knownCodes[code] ?? "Unknown trouble code"
    }

    static let knownCodes: [String: String] = [
        // General powertrain
        "P0100": "Mass Air Flow (MAF) sensor circuit malfunction",
        "P0101": "MAF sensor range/performance problem",
        "P0102": "MAF sensor circuit low input",
        "P0103": "MAF sensor circuit high input",
        "P0110": "Intake Air Temperature (IAT) sensor circuit malfunction",
        "P0112": "IAT sensor circuit low input",
        "P0113": "IAT sensor circuit high input",
        "P0115": "Engine Coolant Temperature (ECT) sensor circuit malfunction",
        "P0116": "ECT sensor range/performance",
        "P0117": "ECT sensor circuit low input",
        "P0118": "ECT sensor circuit high input",
        "P0120": "Throttle Position Sensor (TPS) circuit malfunction",
        "P0121": "TPS range/performance problem",
        "P0122": "TPS circuit low input",
        "P0123": "TPS circuit high input",
        "P0125": "Insufficient coolant temperature for closed loop fuel control",
        "P0128": "Coolant thermostat below regulating temperature",
        "P0130": "O2 sensor circuit malfunction (Bank 1, Sensor 1)",
        "P0131": "O2 sensor low voltage (Bank 1, Sensor 1)",
        "P0132": "O2 sensor high voltage (Bank 1, Sensor 1)",
        "P0133": "O2 sensor slow response (Bank 1, Sensor 1)",
        "P0134": "O2 sensor no activity detected (Bank 1, Sensor 1)",
        "P0135": "O2 sensor heater circuit (Bank 1, Sensor 1)",
        "P0136": "O2 sensor circuit malfunction (Bank 1, Sensor 2)",
        "P0137": "O2 sensor low voltage (Bank 1, Sensor 2)",
        "P0138": "O2 sensor high voltage (Bank 1, Sensor 2)",
        "P0139": "O2 sensor slow response (Bank 1, Sensor 2)",
        "P0141": "O2 sensor heater circuit (Bank 1, Sensor 2)",
        "P0171": "System too lean (Bank 1)",
        "P0172": "System too rich (Bank 1)",
        "P0174": "System too lean (Bank 2)",
        "P0175": "System too rich (Bank 2)",

        // Fuel / ignition
        "P0300": "Random/multiple cylinder misfire detected",
        "P0301": "Cylinder 1 misfire detected",
        "P0302": "Cylinder 2 misfire detected",
        "P0303": "Cylinder 3 misfire detected",
        "P0304": "Cylinder 4 misfire detected",
        "P0325": "Knock sensor circuit malfunction (Bank 1)",
        "P0330": "Knock sensor circuit malfunction (Bank 2)",
        "P0335": "Crankshaft Position Sensor circuit malfunction",
        "P0340": "Camshaft Position Sensor circuit malfunction (Bank 1)",
        "P0341": "Camshaft Position Sensor range/performance (Bank 1)",
        "P0351": "Ignition coil A primary/secondary circuit malfunction",
        "P0352": "Ignition coil B primary/secondary circuit malfunction",
        "P0353": "Ignition coil C primary/secondary circuit malfunction",
        "P0354": "Ignition coil D primary/secondary circuit malfunction",

        // Fuel system
        "P0400": "EGR flow malfunction",
        "P0401": "EGR insufficient flow detected",
        "P0402": "EGR excessive flow detected",
        "P0420": "Catalyst system efficiency below threshold (Bank 1)",
        "P0430": "Catalyst system efficiency below threshold (Bank 2)",
        "P0440": "EVAP emission control system malfunction",
        "P0441": "EVAP system incorrect purge flow",
        "P0442": "EVAP system small leak detected",
        "P0443": "EVAP purge control valve circuit malfunction",
        "P0446": "EVAP vent control circuit malfunction",
        "P0450": "EVAP pressure sensor malfunction",
        "P0451": "EVAP pressure sensor range/performance",
        "P0452": "EVAP pressure sensor low input",
        "P0453": "EVAP pressure sensor high input",
        "P0455": "EVAP system large leak detected",
        "P0456": "EVAP system very small leak detected",

        // Vehicle speed / idle
        "P0500": "Vehicle Speed Sensor malfunction",
        "P0505": "Idle Air Control system malfunction",
        "P0507": "Idle control system RPM higher than expected",

        // Toyota / RAV4 Hybrid specific
        "P0A80": "Replace hybrid battery pack",
        "P0A7F": "Hybrid battery pack deterioration",
        "P0A94": "DC/DC converter performance",
        "P0AA6": "Hybrid battery voltage system isolation fault",
        "P0AFA": "Hybrid battery current sensor circuit",
        "P3000": "HV battery control system malfunction",
        "P3001": "Battery control module malfunction",
        "P3004": "Battery block 1 low",
        "P3005": "Battery block 2 low",
        "P3006": "Battery block 3 low",
        "P3007": "Battery block 4 low",
        "P3009": "High voltage leak detected",
        "P3011": "Battery block 1 abnormal",
        "P3012": "Battery block 2 abnormal",
        "P3013": "Battery block 3 abnormal",
        "P3014": "Battery block 4 abnormal",
        "P3017": "Battery ECU malfunction",
        "P3020": "Battery SOC unbalanced",
        "P3100": "HV ECU malfunction",
        "P3101": "Engine system malfunction (hybrid)",
        "P3102": "Motor system malfunction (MG1)",
        "P3103": "Motor system malfunction (MG2)",
        "P3115": "Transaxle assembly malfunction",
        "P3120": "Inverter cooling system malfunction",
        "P3125": "Inverter malfunction (MG1)",
        "P3130": "Inverter malfunction (MG2)",

        // Transmission
        "P0700": "Transmission control system malfunction",
        "P0710": "Transmission fluid temperature sensor circuit malfunction",
        "P0715": "Input/turbine speed sensor circuit malfunction",
        "P0717": "Input/turbine speed sensor no signal",
        "P0720": "Output speed sensor circuit malfunction",
        "P0741": "Torque converter clutch solenoid performance",
        "P0750": "Shift solenoid A malfunction",
        "P0755": "Shift solenoid B malfunction",
        "P0760": "Shift solenoid C malfunction",
        "P0765": "Shift solenoid D malfunction",
        "P0770": "Shift solenoid E malfunction",

        // Body
        "B1000": "Body ECU malfunction",
        "B1050": "Air bag system malfunction",
        "B1051": "Air bag deployment criteria met",

        // Chassis
        "C1201": "Engine control system malfunction (VSC signal)",
        "C1241": "Low battery positive voltage (ABS/VSC)",
        "C1249": "Open in stop lamp switch circuit",
        "C1252": "Malfunction in ABS pump motor circuit",
        "C1256": "Malfunction in ABS/VSC sensor",

        // Network
        "U0100": "Lost communication with ECM/PCM",
        "U0101": "Lost communication with TCM",
        "U0121": "Lost communication with ABS",
        "U0122": "Lost communication with VSC",
        "U0140": "Lost communication with body control module",
        "U0155": "Lost communication with cluster/instrument panel",
        "U0164": "Lost communication with HVAC control module",
    ]
}
