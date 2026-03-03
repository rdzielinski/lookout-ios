import Foundation
import Observation

@Observable
final class DrivingDataStore {

    // MARK: - Live Sensor Values

    var engineRPM: Double = 0
    var vehicleSpeedKmh: Double = 0
    var mafRate: Double = 0
    var engineLoad: Double = 0
    var throttlePosition: Double = 0
    var coolantTemp: Double = -40
    var intakeAirTemp: Double = -40
    var ambientTemp: Double = -40
    var fuelLevel: Double = 0
    var barometricPressure: Double = 0
    var acceleratorPedal: Double = 0

    // MARK: - Computed Values

    var vehicleSpeedMph: Double { Units.kmhToMph(vehicleSpeedKmh) }
    var isEVMode: Bool { engineRPM < 50 && vehicleSpeedKmh > 2 }
    var isEngineRunning: Bool { engineRPM > 50 }
    var isStationary: Bool { vehicleSpeedKmh < 1 }

    var gallonsPerHour: Double {
        Units.gallonsPerHour(mafGramsPerSec: mafRate)
    }

    var instantMPG: Double? {
        Units.instantMPG(speedKmh: vehicleSpeedKmh, mafGramsPerSec: mafRate)
    }

    var coolantTempF: Double { Units.celsiusToFahrenheit(coolantTemp) }
    var ambientTempF: Double { Units.celsiusToFahrenheit(ambientTemp) }
    var isEngineWarmedUp: Bool { coolantTemp >= 80 }

    // MARK: - History (for coaching analysis)

    private(set) var recentThrottlePositions: [Double] = []
    private(set) var recentRPMs: [Double] = []
    private(set) var recentSpeeds: [Double] = []
    private let historySize = 120

    // MARK: - Session Tracking

    var initialAmbientTemp: Double?
    var lastUpdateTime: Date = .now

    // MARK: - Update

    func update(with response: OBDResponse) {
        lastUpdateTime = Date()

        switch response.pid.pid {
        case 0x04: engineLoad = response.value
        case 0x05: coolantTemp = response.value
        case 0x0C:
            engineRPM = response.value
            appendToHistory(&recentRPMs, value: response.value)
        case 0x0D:
            vehicleSpeedKmh = response.value
            appendToHistory(&recentSpeeds, value: response.value)
        case 0x0F: intakeAirTemp = response.value
        case 0x10: mafRate = response.value
        case 0x11:
            throttlePosition = response.value
            appendToHistory(&recentThrottlePositions, value: response.value)
        case 0x2F: fuelLevel = response.value
        case 0x33: barometricPressure = response.value
        case 0x46:
            ambientTemp = response.value
            if initialAmbientTemp == nil {
                initialAmbientTemp = response.value
            }
        case 0x49: acceleratorPedal = response.value
        default: break
        }
    }

    private func appendToHistory(_ buffer: inout [Double], value: Double) {
        buffer.append(value)
        if buffer.count > historySize { buffer.removeFirst() }
    }
}
