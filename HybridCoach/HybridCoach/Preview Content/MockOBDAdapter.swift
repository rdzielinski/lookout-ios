import Foundation
import CoreBluetooth

/// Generates fake OBD-II data for SwiftUI previews and simulator testing.
final class MockOBDAdapter: OBDAdapter, @unchecked Sendable {
    private(set) var state: AdapterState = .ready
    let adapterType: AdapterType = .elm327

    private var simulationTimer: Timer?
    private var dataStore: DrivingDataStore?
    private var tick: Int = 0

    func configure(peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic, notifyCharacteristic: CBCharacteristic) {}

    func initialize() async throws {
        state = .ready
    }

    func sendPID(_ pid: String) async throws -> [UInt8] {
        // Return simulated data based on PID/Mode
        switch pid {
        case "03": // Stored DTCs — simulate P0420 (catalyst efficiency)
            // P0420 = system 0 (P), digit1=0, digit2=4, digit3=2, digit4=0
            // highByte = 00000100 = 0x04, lowByte = 00100000 = 0x20
            return [0x04, 0x20, 0x00, 0x00]
        case "07": // Pending DTCs — simulate P0171 (system too lean)
            // P0171 = highByte = 0x01, lowByte = 0x71
            return [0x01, 0x71, 0x00, 0x00]
        case "04": // Clear DTCs — return success
            return [0x44]
        case "010C": // RPM: simulate 800-2500 range
            let rpm = UInt16(800 + Int.random(in: 0...1700))
            let encoded = rpm * 4
            return [UInt8(encoded >> 8), UInt8(encoded & 0xFF)]
        case "010D": // Speed: simulate 0-100 km/h
            return [UInt8(Int.random(in: 30...100))]
        case "0110": // MAF: simulate 2-15 g/s
            let maf = UInt16(Int.random(in: 200...1500))
            return [UInt8(maf >> 8), UInt8(maf & 0xFF)]
        case "0111": // Throttle: 10-60%
            return [UInt8(Int.random(in: 25...153))]
        case "0104": // Engine Load: 20-70%
            return [UInt8(Int.random(in: 51...178))]
        case "0149": // Accelerator Pedal: 5-50%
            return [UInt8(Int.random(in: 13...128))]
        case "0105": // Coolant temp: 80-95C
            return [UInt8(Int.random(in: 120...135))] // +40 offset
        case "010F": // Intake air temp: 20-40C
            return [UInt8(Int.random(in: 60...80))]
        case "0146": // Ambient temp: 20-30C
            return [UInt8(Int.random(in: 60...70))]
        case "012F": // Fuel level: 50-80%
            return [UInt8(Int.random(in: 128...204))]
        case "0133": // Baro pressure: 100-102 kPa
            return [UInt8(Int.random(in: 100...102))]
        default:
            return [0]
        }
    }

    func didReceiveData(_ data: Data) {}
    func disconnect() { state = .disconnected }

    /// Start feeding mock data into a DrivingDataStore for UI testing.
    @MainActor
    func startMockDataFeed(into store: DrivingDataStore) {
        dataStore = store
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            let currentTick = self.tick

            Task { @MainActor [weak self] in
                guard let self, let store = self.dataStore else { return }

                for pid in PIDCatalog.highPriority {
                    if let bytes = try? await self.sendPID(pid.command) {
                        let response = OBDResponse(pid: pid, rawBytes: bytes)
                        store.update(with: response)
                    }
                }
                if currentTick % 2 == 0 {
                    for pid in PIDCatalog.mediumPriority {
                        if let bytes = try? await self.sendPID(pid.command) {
                            let response = OBDResponse(pid: pid, rawBytes: bytes)
                            store.update(with: response)
                        }
                    }
                }
                if currentTick % 5 == 0 {
                    for pid in PIDCatalog.lowPriority {
                        if let bytes = try? await self.sendPID(pid.command) {
                            let response = OBDResponse(pid: pid, rawBytes: bytes)
                            store.update(with: response)
                        }
                    }
                }
            }
        }
    }

    func stopMockDataFeed() {
        simulationTimer?.invalidate()
        simulationTimer = nil
    }
}
