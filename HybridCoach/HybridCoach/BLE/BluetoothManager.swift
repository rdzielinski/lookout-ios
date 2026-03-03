import Foundation
import CoreBluetooth

struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    var rssi: Int
    var id: UUID { peripheral.identifier }
}

@Observable
final class BluetoothManager: NSObject, @unchecked Sendable {

    enum ConnectionState {
        case disconnected
        case bluetoothOff
        case scanning
        case connecting
        case connected
        case ready
    }

    // MARK: - Published State

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var isScanning = false
    private(set) var discoveredDevices: [DiscoveredDevice] = []
    private(set) var connectedPeripheral: CBPeripheral?
    private(set) var adapterInfo: String?
    private(set) var discoveredGATTInfo: String = ""
    var errorMessage: String = ""

    /// The currently active OBD adapter (available when state == .ready).
    private(set) var connectedAdapter: OBDAdapter?

    // MARK: - Callbacks

    var onAdapterReady: ((OBDAdapter) -> Void)?

    // MARK: - Private

    private var centralManager: CBCentralManager!
    private var connectingPeripheral: CBPeripheral?
    private var discoveredServices: [CBService] = []
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private(set) var detectedAdapterType: AdapterType = .unknown
    private var gattDump: [String] = []

    // Protocol Analyzer support
    var protocolAnalyzerStore: ProtocolAnalyzerStore?
    private var pendingGATTReads: Set<CBUUID> = []

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScan() {
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothOff
            errorMessage = "Bluetooth is not available. Please enable Bluetooth in Settings."
            return
        }

        discoveredDevices.removeAll()
        errorMessage = ""
        isScanning = true
        connectionState = .scanning

        // Scan for known ELM327 services + all devices (to catch AutoPhix)
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Auto-stop after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.isScanning else { return }
            self.stopScan()
        }
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        connectingPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        errorMessage = ""
        gattDump.removeAll()
        discoveredGATTInfo = ""

        centralManager.connect(peripheral, options: nil)

        // Timeout — use connectingPeripheral reference to avoid sending non-Sendable CBPeripheral
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEConstants.connectionTimeout) { [weak self] in
            guard let self, self.connectionState == .connecting else { return }
            if let p = self.connectingPeripheral {
                self.centralManager.cancelPeripheralConnection(p)
            }
            self.connectionState = .disconnected
            self.errorMessage = "Connection timed out. Make sure the adapter is powered and nearby."
        }
    }

    func disconnect() {
        if let peripheral = connectedPeripheral ?? connectingPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    /// Create a ProtocolProber using the current connection's characteristics.
    func createProtocolProber() -> ProtocolProber? {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic,
              let notifyChar = notifyCharacteristic,
              let store = protocolAnalyzerStore else { return nil }

        return ProtocolProber(
            peripheral: peripheral,
            writeCharacteristic: writeChar,
            notifyCharacteristic: notifyChar,
            store: store
        )
    }

    // MARK: - Private Helpers

    private func cleanup() {
        connectedAdapter?.disconnect()
        connectedAdapter = nil
        connectedPeripheral = nil
        connectingPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectionState = .disconnected
        detectedAdapterType = .unknown
    }

    private func isOBDAdapter(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }

        // Check AutoPhix names
        for apName in BLEConstants.autoPhixAdvertisedNames {
            if name.localizedCaseInsensitiveContains(apName) { return true }
        }

        // Check ELM327 names
        for elmName in BLEConstants.elm327AdvertisedNames {
            if name.localizedCaseInsensitiveContains(elmName) { return true }
        }

        return false
    }

    private func identifyAdapterType(name: String) -> AdapterType {
        for apName in BLEConstants.autoPhixAdvertisedNames {
            if name.localizedCaseInsensitiveContains(apName) { return .autoPhix }
        }
        return .elm327
    }

    private func findCharacteristics() {
        // Strategy: look for known ELM327 GATT profiles first, then fall back to generic discovery

        for service in discoveredServices {
            // Profile 1: FFF0 service
            if service.uuid == BLEConstants.ELM327Profile1.serviceUUID {
                for char in service.characteristics ?? [] {
                    if char.uuid == BLEConstants.ELM327Profile1.writeCharUUID &&
                       char.properties.contains(.writeWithoutResponse) {
                        writeCharacteristic = char
                    }
                    if char.uuid == BLEConstants.ELM327Profile1.notifyCharUUID &&
                       char.properties.contains(.notify) {
                        notifyCharacteristic = char
                    }
                }
            }

            // Profile 2: FFE0 service (single char for read/write/notify)
            if service.uuid == BLEConstants.ELM327Profile2.serviceUUID {
                for char in service.characteristics ?? [] {
                    if char.uuid == BLEConstants.ELM327Profile2.charUUID {
                        writeCharacteristic = char
                        notifyCharacteristic = char
                    }
                }
            }

            // ISSC Profile
            if service.uuid == BLEConstants.ISSCProfile.serviceUUID {
                for char in service.characteristics ?? [] {
                    if char.uuid == BLEConstants.ISSCProfile.writeCharUUID {
                        writeCharacteristic = char
                    }
                    if char.uuid == BLEConstants.ISSCProfile.notifyCharUUID {
                        notifyCharacteristic = char
                    }
                }
            }
        }

        // Fallback: find any writable + notifiable characteristic pair
        if writeCharacteristic == nil || notifyCharacteristic == nil {
            for service in discoveredServices {
                for char in service.characteristics ?? [] {
                    if writeCharacteristic == nil &&
                       (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) {
                        writeCharacteristic = char
                    }
                    if notifyCharacteristic == nil && char.properties.contains(.notify) {
                        notifyCharacteristic = char
                    }
                }
            }
        }

        // Build GATT dump for debugging
        discoveredGATTInfo = gattDump.joined(separator: "\n")

        // Populate protocol analyzer store (if active)
        populateAnalyzerStore()

        if let write = writeCharacteristic, let notify = notifyCharacteristic {
            // Subscribe to notifications
            connectedPeripheral?.setNotifyValue(true, for: notify)

            // Create the appropriate adapter
            let adapter: OBDAdapter
            let peripheral = connectedPeripheral!

            if detectedAdapterType == .autoPhix {
                let apAdapter = AutoPhixAdapter()
                apAdapter.configure(peripheral: peripheral, writeCharacteristic: write, notifyCharacteristic: notify)
                adapter = apAdapter
            } else {
                let elmAdapter = ELM327Adapter()
                elmAdapter.configure(peripheral: peripheral, writeCharacteristic: write, notifyCharacteristic: notify)
                adapter = elmAdapter
            }

            adapterInfo = "Type: \(detectedAdapterType)\nWrite: \(write.uuid)\nNotify: \(notify.uuid)"
            connectedAdapter = adapter
            connectionState = .ready
            onAdapterReady?(adapter)
        } else {
            errorMessage = "Could not find compatible GATT characteristics. Check GATT Services for details."
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectionState == .bluetoothOff {
                connectionState = .disconnected
            }
        case .poweredOff:
            connectionState = .bluetoothOff
            cleanup()
        case .unauthorized:
            errorMessage = "Bluetooth permission denied. Enable in Settings > Privacy > Bluetooth."
            connectionState = .disconnected
        case .unsupported:
            errorMessage = "Bluetooth LE is not supported on this device."
            connectionState = .disconnected
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isOBDAdapter(peripheral) else { return }

        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].rssi = RSSI.intValue
        } else {
            discoveredDevices.append(DiscoveredDevice(peripheral: peripheral, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectingPeripheral = nil
        connectionState = .connected
        detectedAdapterType = identifyAdapterType(name: peripheral.name ?? "")

        // Discover all services (full GATT enumeration for AutoPhix)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        errorMessage = "Failed to connect: \(error?.localizedDescription ?? "Unknown error")"
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            errorMessage = "Disconnected: \(error.localizedDescription)"
        }
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            errorMessage = "No services found on device."
            return
        }

        discoveredServices = services

        for service in services {
            gattDump.append("Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        for char in chars {
            let props = describeProperties(char.properties)
            gattDump.append("  Char: \(char.uuid) [\(props)]")
        }

        // Check if all services have had characteristics discovered
        let allDiscovered = discoveredServices.allSatisfy { svc in
            svc.characteristics != nil
        }

        if allDiscovered {
            findCharacteristics()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        // Handle GATT discovery reads for analyzer store
        if pendingGATTReads.contains(characteristic.uuid) {
            pendingGATTReads.remove(characteristic.uuid)
            updateAnalyzerStoreCharValue(uuid: characteristic.uuid, data: data)
            return
        }

        // Forward raw data to the active adapter
        NotificationCenter.default.post(
            name: .init("OBDDataReceived"),
            object: nil,
            userInfo: ["data": data]
        )
    }

    private func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("R") }
        if props.contains(.write) { parts.append("W") }
        if props.contains(.writeWithoutResponse) { parts.append("WnR") }
        if props.contains(.notify) { parts.append("N") }
        if props.contains(.indicate) { parts.append("I") }
        return parts.joined(separator: ",")
    }

    // MARK: - Protocol Analyzer Helpers

    private func populateAnalyzerStore() {
        guard let store = protocolAnalyzerStore, let peripheral = connectedPeripheral else { return }

        store.isActive = true
        store.deviceInfo.peripheralName = peripheral.name
        store.deviceInfo.peripheralUUID = peripheral.identifier
        store.gattCharacteristics.removeAll()

        for service in discoveredServices {
            let serviceName = Self.resolveServiceName(service.uuid)
            for char in service.characteristics ?? [] {
                let charName = Self.resolveCharacteristicName(char.uuid)
                let props = describeProperties(char.properties)

                let info = GATTCharacteristicInfo(
                    serviceUUID: service.uuid,
                    serviceName: serviceName,
                    characteristicUUID: char.uuid,
                    characteristicName: charName,
                    properties: props,
                    readValue: nil,
                    readValueString: nil
                )
                store.gattCharacteristics.append(info)

                // Read readable characteristics to get their values
                if char.properties.contains(.read) {
                    pendingGATTReads.insert(char.uuid)
                    peripheral.readValue(for: char)
                }
            }
        }
    }

    private func updateAnalyzerStoreCharValue(uuid: CBUUID, data: Data) {
        guard let store = protocolAnalyzerStore else { return }

        let stringValue = String(data: data, encoding: .utf8)

        // Update the GATT characteristic info
        if let idx = store.gattCharacteristics.firstIndex(where: { $0.characteristicUUID == uuid }) {
            let existing = store.gattCharacteristics[idx]
            store.gattCharacteristics[idx] = GATTCharacteristicInfo(
                serviceUUID: existing.serviceUUID,
                serviceName: existing.serviceName,
                characteristicUUID: existing.characteristicUUID,
                characteristicName: existing.characteristicName,
                properties: existing.properties,
                readValue: data,
                readValueString: stringValue
            )
        }

        // Update Device Info fields
        switch uuid {
        case BLEConstants.DeviceInfoService.manufacturerNameUUID:
            store.deviceInfo.manufacturerName = stringValue
        case BLEConstants.DeviceInfoService.modelNumberUUID:
            store.deviceInfo.modelNumber = stringValue
        case BLEConstants.DeviceInfoService.serialNumberUUID:
            store.deviceInfo.serialNumber = stringValue
        case BLEConstants.DeviceInfoService.firmwareRevisionUUID:
            store.deviceInfo.firmwareRevision = stringValue
        case BLEConstants.DeviceInfoService.hardwareRevisionUUID:
            store.deviceInfo.hardwareRevision = stringValue
        case BLEConstants.DeviceInfoService.softwareRevisionUUID:
            store.deviceInfo.softwareRevision = stringValue
        default:
            break
        }
    }

    // MARK: - UUID Name Resolution

    static func resolveServiceName(_ uuid: CBUUID) -> String? {
        switch uuid {
        case BLEConstants.DeviceInfoService.serviceUUID: return "Device Information"
        case BLEConstants.ELM327Profile1.serviceUUID: return "ELM327 (FFF0)"
        case BLEConstants.ELM327Profile2.serviceUUID: return "ELM327 (FFE0)"
        case BLEConstants.ISSCProfile.serviceUUID: return "ISSC Transparent UART"
        case CBUUID(string: "1800"): return "Generic Access"
        case CBUUID(string: "1801"): return "Generic Attribute"
        default: return nil
        }
    }

    static func resolveCharacteristicName(_ uuid: CBUUID) -> String? {
        switch uuid {
        case BLEConstants.DeviceInfoService.manufacturerNameUUID: return "Manufacturer Name"
        case BLEConstants.DeviceInfoService.modelNumberUUID: return "Model Number"
        case BLEConstants.DeviceInfoService.serialNumberUUID: return "Serial Number"
        case BLEConstants.DeviceInfoService.firmwareRevisionUUID: return "Firmware Revision"
        case BLEConstants.DeviceInfoService.hardwareRevisionUUID: return "Hardware Revision"
        case BLEConstants.DeviceInfoService.softwareRevisionUUID: return "Software Revision"
        case BLEConstants.ELM327Profile1.writeCharUUID: return "ELM327 Write (FFF2)"
        case BLEConstants.ELM327Profile1.notifyCharUUID: return "ELM327 Notify (FFF1)"
        case BLEConstants.ELM327Profile2.charUUID: return "ELM327 RW/Notify (FFE1)"
        case BLEConstants.ISSCProfile.writeCharUUID: return "ISSC Write"
        case BLEConstants.ISSCProfile.notifyCharUUID: return "ISSC Notify"
        case CBUUID(string: "2A00"): return "Device Name"
        case CBUUID(string: "2A01"): return "Appearance"
        case CBUUID(string: "2A04"): return "Preferred Conn Params"
        default: return nil
        }
    }
}
