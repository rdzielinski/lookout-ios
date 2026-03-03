import SwiftUI

struct TripHistoryView: View {
    @Environment(TripRecorder.self) var recorder

    var body: some View {
        NavigationStack {
            List {
                if let current = recorder.currentTrip {
                    Section("Current Trip") {
                        tripRow(current, isCurrent: true)
                    }
                }

                Section("Past Trips") {
                    if recorder.pastTrips.isEmpty {
                        ContentUnavailableView(
                            "No Trip History",
                            systemImage: "car.side",
                            description: Text("Completed trips will appear here. Connect to your OBD-II adapter and start driving.")
                        )
                    } else {
                        ForEach(recorder.pastTrips) { trip in
                            NavigationLink(value: trip.id) {
                                tripRow(trip, isCurrent: false)
                            }
                        }
                        .onDelete { indexSet in
                            recorder.deleteTrips(at: indexSet)
                        }
                    }
                }

                if !recorder.pastTrips.isEmpty {
                    Section("Summary") {
                        summaryStats

                        NavigationLink {
                            LifetimeStatsView()
                        } label: {
                            Label("View Lifetime Stats & Trends", systemImage: "chart.line.uptrend.xyaxis")
                        }
                    }
                }
            }
            .navigationTitle("Trips")
            .navigationDestination(for: UUID.self) { tripID in
                if let trip = recorder.pastTrips.first(where: { $0.id == tripID }) {
                    TripDetailView(trip: trip)
                }
            }
        }
    }

    private func tripRow(_ trip: Trip, isCurrent: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(trip.startTime, style: .date)
                        .font(.subheadline)
                    Text(trip.startTime, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Label(String(format: "%.1f mi", trip.distanceMiles), systemImage: "road.lanes")
                    Label(trip.durationFormatted, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isCurrent {
                    Text("LIVE")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                } else {
                    Text("\(trip.averageEfficiencyScore)")
                        .font(.title3.bold())
                        .foregroundStyle(scoreColor(trip.averageEfficiencyScore))
                }

                Text(String(format: "%.1f MPG", trip.averageMPG))
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }

    private var summaryStats: some View {
        let trips = recorder.pastTrips
        let totalMiles = trips.reduce(0.0) { $0 + $1.distanceMiles }
        let totalGallons = trips.reduce(0.0) { $0 + $1.fuelUsedGallons }
        let avgMPG = totalGallons > 0.001 ? totalMiles / totalGallons : 0
        let avgScore = trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.averageEfficiencyScore } / trips.count

        return VStack(spacing: 8) {
            HStack {
                statTile(title: "Total Trips", value: "\(trips.count)")
                statTile(title: "Total Miles", value: String(format: "%.1f", totalMiles))
            }
            HStack {
                statTile(title: "Overall MPG", value: String(format: "%.1f", avgMPG))
                statTile(title: "Avg Score", value: "\(avgScore)")
            }
        }
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 90...100: .green
        case 70..<90: .blue
        case 50..<70: .orange
        default: .red
        }
    }
}
