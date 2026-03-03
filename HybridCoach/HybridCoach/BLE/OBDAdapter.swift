import Foundation
import CoreBluetooth

enum AdapterState: Equatable {
    case disconnected
    case connecting
    case connectedToAdapter
    case initializing
    case ready
    case error(String)
}

enum AdapterType: String {
    case elm327 = "ELM327"
    case autoPhix = "AutoPhix"
    case unknown = "Unknown"
}

protocol OBDAdapter: AnyObject, Sendable {
    var state: AdapterState { get }
    var adapterType: AdapterType { get }

    /// Called after BLE connection and service/characteristic discovery is complete.
    func configure(
        peripheral: CBPeripheral,
        writeCharacteristic: CBCharacteristic,
        notifyCharacteristic: CBCharacteristic
    )

    /// Initialize the adapter (AT commands for ELM327, proprietary for AutoPhix).
    func initialize() async throws

    /// Send a raw OBD-II PID request and return the data bytes.
    /// e.g., sendPID("010C") returns bytes after the "41 0C" header.
    func sendPID(_ pid: String) async throws -> [UInt8]

    /// Called when BLE data arrives on the notify characteristic.
    func didReceiveData(_ data: Data)

    /// Clean shutdown.
    func disconnect()
}

enum OBDAdapterError: LocalizedError {
    case notConnected
    case notInitialized
    case timeout
    case noData
    case noResponse
    case protocolError(String)
    case invalidResponse(String)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Adapter not connected"
        case .notInitialized: "Adapter not initialized"
        case .timeout: "Command timed out"
        case .noData: "No data received from vehicle"
        case .noResponse: "No response from adapter"
        case .protocolError(let msg): "Protocol error: \(msg)"
        case .invalidResponse(let msg): "Invalid response: \(msg)"
        case .initializationFailed(let msg): "Initialization failed: \(msg)"
        }
    }
}
