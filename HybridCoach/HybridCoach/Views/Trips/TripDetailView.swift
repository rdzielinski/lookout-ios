import SwiftUI

struct TripDetailView: View {
    let trip: Trip
    @Environment(RouteStore.self) var routeStore

    /// Find the RouteRecord that was created from this trip.
    private var matchingRouteRecord: RouteRecord? {
        routeStore.routes.first(where: { $0.tripID == trip.id })
    }

    /// Whether this trip has GPS data in its snapshots.
    private var hasGPSData: Bool {
        trip.snapshots.contains(where: { $0.latitude != nil && $0.longitude != nil })
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text("\(trip.averageEfficiencyScore)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor)

                    Text(scoreLabel)
                        .font(.headline)
                        .foregroundStyle(scoreColor)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Section("Trip Stats") {
                statRow(icon: "road.lanes", title: "Distance", value: String(format: "%.1f mi", trip.distanceMiles))
                statRow(icon: "clock", title: "Duration", value: trip.durationFormatted)
                statRow(icon: "fuelpump", title: "Fuel Used", value: String(format: "%.2f gal", trip.fuelUsedGallons))
                statRow(icon: "gauge.with.dots.needle.67percent", title: "Average MPG", value: String(format: "%.1f", trip.averageMPG))
            }

            Section("Performance") {
                statRow(icon: "bolt.fill", title: "EV Mode", value: String(format: "%.0f%%", trip.evModePercentage))
                statRow(icon: "gauge.with.dots.needle.33percent", title: "Max RPM", value: String(format: "%.0f", trip.maxRPM))
                statRow(icon: "speedometer", title: "Max Speed", value: String(format: "%.0f mph", trip.maxSpeedMph))
            }

            // Route Analysis — shown when GPS data is available
            if hasGPSData {
                Section("Route Analysis") {
                    NavigationLink {
                        TripImprovementMapView(trip: trip, routeRecord: matchingRouteRecord)
                    } label: {
                        Label("View Improvement Map", systemImage: "map.fill")
                    }
                }
            }

            if trip.snapshots.count > 2 {
                Section("Charts") {
                    TripChartView(trip: trip)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Timeline") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(trip.startTime, style: .time)
                            .font(.subheadline)
                        Text(trip.startTime, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let endTime = trip.endTime {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Ended")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(endTime, style: .time)
                                .font(.subheadline)
                            Text(endTime, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Trip Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var scoreColor: Color {
        switch trip.averageEfficiencyScore {
        case 90...100: .green
        case 70..<90: .blue
        case 50..<70: .orange
        default: .red
        }
    }

    private var scoreLabel: String {
        switch trip.averageEfficiencyScore {
        case 90...100: "Excellent"
        case 70..<90: "Good"
        case 50..<70: "Fair"
        default: "Needs Improvement"
        }
    }
}
