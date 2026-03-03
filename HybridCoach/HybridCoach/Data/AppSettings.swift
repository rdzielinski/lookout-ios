import SwiftUI

/// App-wide user preferences, persisted via UserDefaults.
@Observable
final class AppSettings {

    // MARK: - Unit System

    enum UnitSystem: String, CaseIterable, Codable {
        case imperial = "Imperial"
        case metric = "Metric"
    }

    var unitSystem: UnitSystem {
        didSet { save("unitSystem", unitSystem.rawValue) }
    }

    // MARK: - Coaching Intensity

    enum CoachingIntensity: String, CaseIterable, Codable {
        case relaxed = "Relaxed"
        case normal = "Normal"
        case aggressive = "Aggressive"
    }

    var coachingIntensity: CoachingIntensity {
        didSet { save("coachingIntensity", coachingIntensity.rawValue) }
    }

    // MARK: - EV Goal

    /// Target EV-mode percentage (20–80 %).
    var evGoalPercentage: Double {
        didSet { save("evGoalPercentage", evGoalPercentage) }
    }

    // MARK: - Preferred Adapter

    var preferredAdapterName: String {
        didSet { save("preferredAdapterName", preferredAdapterName) }
    }

    // MARK: - Simulator Mode

    /// When enabled, feeds simulated OBD-II data for indoor testing without a real adapter.
    var simulatorMode: Bool {
        didSet { save("simulatorMode", simulatorMode) }
    }

    // MARK: - Appearance

    enum AppearanceMode: String, CaseIterable, Codable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var appearanceMode: AppearanceMode {
        didSet { save("appearanceMode", appearanceMode.rawValue) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.unitSystem = UnitSystem(rawValue: defaults.string(forKey: "unitSystem") ?? "") ?? .imperial
        self.coachingIntensity = CoachingIntensity(rawValue: defaults.string(forKey: "coachingIntensity") ?? "") ?? .normal
        self.evGoalPercentage = defaults.object(forKey: "evGoalPercentage") as? Double ?? 40.0
        self.preferredAdapterName = defaults.string(forKey: "preferredAdapterName") ?? ""
        self.simulatorMode = defaults.bool(forKey: "simulatorMode")
        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    // MARK: - Helpers

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
