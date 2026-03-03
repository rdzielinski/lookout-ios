import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                Section("Units") {
                    Picker("Unit System", selection: $settings.unitSystem) {
                        ForEach(AppSettings.UnitSystem.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                }

                Section("Coaching") {
                    Picker("Coaching Intensity", selection: $settings.coachingIntensity) {
                        ForEach(AppSettings.CoachingIntensity.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("EV Mode Goal")
                            Spacer()
                            Text("\(Int(settings.evGoalPercentage))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.evGoalPercentage, in: 20...80, step: 5)
                            .tint(.green)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(AppSettings.AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                Section("Connection") {
                    HStack {
                        Text("Preferred Adapter")
                        Spacer()
                        Text(settings.preferredAdapterName.isEmpty ? "Any" : settings.preferredAdapterName)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
