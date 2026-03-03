@preconcurrency import CoreBluetooth

enum BLEConstants {

    // MARK: - ELM327 BLE GATT Profiles

    /// Most common Chinese ELM327 BLE adapters (FFF0/FFF1/FFF2)
    enum ELM327Profile1 {
        static let serviceUUID = CBUUID(string: "FFF0")
        static let notifyCharUUID = CBUUID(string: "FFF1")
        static let writeCharUUID = CBUUID(string: "FFF2")
    }

    /// Alternate profile (FFE0/FFE1) used by some adapters
    enum ELM327Profile2 {
        static let serviceUUID = CBUUID(string: "FFE0")
        static let charUUID = CBUUID(string: "FFE1") // same char for read/write/notify
    }

    /// ISSC Transparent UART (higher-end adapters like OBDLink)
    enum ISSCProfile {
        static let serviceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
        static let notifyCharUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
        static let writeCharUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
    }

    /// All known ELM327 service UUIDs for quick matching
    static let knownELM327ServiceUUIDs: [CBUUID] = [
        ELM327Profile1.serviceUUID,
        ELM327Profile2.serviceUUID,
        ISSCProfile.serviceUUID
    ]

    // MARK: - AutoPhix 3210

    /// Known advertised names for the AutoPhix 3210
    static let autoPhixAdvertisedNames = ["AUTOPHIX", "AP3210", "3210", "Autophix", "autophix"]

    // MARK: - Common ELM327 Advertised Names

    static let elm327AdvertisedNames = [
        "OBDII", "OBD", "ELM327", "Vgate", "Veepeak",
        "iCar", "OBDLink", "LELink", "KONNWEI", "V-LINK"
    ]

    // MARK: - Device Information Service (0x180A)

    enum DeviceInfoService {
        static let serviceUUID = CBUUID(string: "180A")
        static let manufacturerNameUUID = CBUUID(string: "2A29")
        static let modelNumberUUID = CBUUID(string: "2A24")
        static let serialNumberUUID = CBUUID(string: "2A25")
        static let firmwareRevisionUUID = CBUUID(string: "2A26")
        static let hardwareRevisionUUID = CBUUID(string: "2A27")
        static let softwareRevisionUUID = CBUUID(string: "2A28")
    }

    // MARK: - Timeouts

    static let connectionTimeout: TimeInterval = 10.0
    static let commandTimeout: TimeInterval = 5.0
    static let initTimeout: TimeInterval = 8.0
}
