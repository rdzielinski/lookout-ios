import Foundation

enum Units {
    static func celsiusToFahrenheit(_ c: Double) -> Double {
        c * 9.0 / 5.0 + 32.0
    }

    static func fahrenheitToCelsius(_ f: Double) -> Double {
        (f - 32.0) * 5.0 / 9.0
    }

    static func kmhToMph(_ kmh: Double) -> Double {
        kmh * 0.621371
    }

    static func mphToKmh(_ mph: Double) -> Double {
        mph / 0.621371
    }

    static func kpaToInHg(_ kpa: Double) -> Double {
        kpa * 0.29530
    }

    /// Gallons per hour from MAF sensor reading in g/s.
    /// Assumes stoichiometric air/fuel ratio of 14.7 and gasoline density of 6.701 lb/gal.
    static func gallonsPerHour(mafGramsPerSec: Double) -> Double {
        mafGramsPerSec * 0.0805228
    }

    /// Instantaneous MPG from speed (km/h) and MAF (g/s).
    /// Returns nil when in EV mode (MAF ~0) or stationary.
    static func instantMPG(speedKmh: Double, mafGramsPerSec: Double) -> Double? {
        guard mafGramsPerSec > 0.1, speedKmh > 1.0 else { return nil }
        let speedMph = kmhToMph(speedKmh)
        let gph = gallonsPerHour(mafGramsPerSec: mafGramsPerSec)
        guard gph > 0.001 else { return nil }
        let mpg = speedMph / gph
        return min(mpg, 199.9)
    }

    // MARK: - Distance Conversions

    static func milesToKm(_ miles: Double) -> Double {
        miles / 0.621371
    }

    static func kmToMiles(_ km: Double) -> Double {
        km * 0.621371
    }

    // MARK: - Fuel Economy Conversions

    /// Converts MPG to liters per 100 km.
    static func mpgToLPer100km(_ mpg: Double) -> Double {
        guard mpg > 0.001 else { return 0 }
        return 235.215 / mpg
    }

    /// Converts liters per 100 km to MPG.
    static func lPer100kmToMpg(_ l100km: Double) -> Double {
        guard l100km > 0.001 else { return 0 }
        return 235.215 / l100km
    }

    // MARK: - Volume Conversions

    static func gallonsToLiters(_ gal: Double) -> Double {
        gal * 3.78541
    }

    static func litersToGallons(_ liters: Double) -> Double {
        liters / 3.78541
    }

    // MARK: - Formatted Strings (unit-aware)

    static func formatSpeed(_ mph: Double, system: AppSettings.UnitSystem) -> String {
        switch system {
        case .imperial:
            return String(format: "%.0f mph", mph)
        case .metric:
            return String(format: "%.0f km/h", mphToKmh(mph))
        }
    }

    static func formatDistance(_ miles: Double, system: AppSettings.UnitSystem) -> String {
        switch system {
        case .imperial:
            return String(format: "%.1f mi", miles)
        case .metric:
            return String(format: "%.1f km", milesToKm(miles))
        }
    }

    static func formatFuelEconomy(_ mpg: Double, system: AppSettings.UnitSystem) -> String {
        switch system {
        case .imperial:
            return String(format: "%.1f MPG", mpg)
        case .metric:
            return String(format: "%.1f L/100km", mpgToLPer100km(mpg))
        }
    }

    static func formatFuelVolume(_ gallons: Double, system: AppSettings.UnitSystem) -> String {
        switch system {
        case .imperial:
            return String(format: "%.2f gal", gallons)
        case .metric:
            return String(format: "%.2f L", gallonsToLiters(gallons))
        }
    }
}
