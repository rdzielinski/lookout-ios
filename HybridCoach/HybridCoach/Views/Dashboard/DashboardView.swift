import SwiftUI

struct DashboardView: View {
    @Environment(DrivingDataStore.self) var data

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Top row: Speed gauge + MPG display
                    HStack(spacing: 16) {
                        GaugeView(
                            value: data.vehicleSpeedMph,
                            maxValue: 120,
                            label: "MPH",
                            color: .blue
                        )

                        MPGDisplayView()
                    }

                    // Middle row: RPM gauge + EV indicator
                    HStack(spacing: 16) {
                        GaugeView(
                            value: data.engineRPM,
                            maxValue: 6000,
                            label: "RPM",
                            color: rpmColor
                        )

                        EVModeIndicator()
                    }

                    // Bottom grid: secondary readouts
                    LazyVGrid(columns: [.init(), .init(), .init()], spacing: 12) {
                        ReadoutTile(
                            title: "Coolant",
                            value: "\(Int(data.coolantTempF))\u{00B0}F",
                            icon: "thermometer.medium"
                        )
                        ReadoutTile(
                            title: "Load",
                            value: "\(Int(data.engineLoad))%",
                            icon: "engine.combustion"
                        )
                        ReadoutTile(
                            title: "Throttle",
                            value: "\(Int(data.throttlePosition))%",
                            icon: "pedal.accelerator"
                        )
                        ReadoutTile(
                            title: "Fuel",
                            value: "\(Int(data.fuelLevel))%",
                            icon: "fuelpump"
                        )
                        ReadoutTile(
                            title: "Outside",
                            value: "\(Int(data.ambientTempF))\u{00B0}F",
                            icon: "sun.max"
                        )
                        ReadoutTile(
                            title: "Airflow",
                            value: String(format: "%.1f g/s", data.mafRate),
                            icon: "wind"
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("HybridCoach")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var rpmColor: Color {
        switch data.engineRPM {
        case 4000...: return .red
        case 3000..<4000: return .orange
        default: return .green
        }
    }
}
