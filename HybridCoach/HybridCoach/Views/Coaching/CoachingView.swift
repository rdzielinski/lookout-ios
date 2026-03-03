import SwiftUI

struct CoachingView: View {
    @Environment(EfficiencyAnalyzer.self) var analyzer
    @Environment(DrivingDataStore.self) var data
    @Environment(EVGoalStore.self) var evGoalStore
    @Environment(AppSettings.self) var settings
    @Environment(RouteStore.self) var routeStore
    @Environment(TripRecorder.self) var tripRecorder

    var body: some View {
        NavigationStack {
            List {
                Section {
                    efficiencyScoreCard
                }

                Section("EV Goal") {
                    evGoalCompactCard
                }

                Section("Current Session") {
                    HStack {
                        Label("EV Mode", systemImage: "bolt.fill")
                        Spacer()
                        Text(data.isEVMode ? "Active" : "Off")
                            .foregroundStyle(data.isEVMode ? .green : .secondary)
                    }

                    if let mpg = data.instantMPG {
                        HStack {
                            Label("Instant MPG", systemImage: "fuelpump")
                            Spacer()
                            Text(String(format: "%.1f", mpg))
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Label("Engine RPM", systemImage: "gauge.with.dots.needle.33percent")
                        Spacer()
                        Text("\(Int(data.engineRPM))")
                            .monospacedDigit()
                            .foregroundStyle(data.engineRPM > 3000 ? .red : .primary)
                    }
                }

                // Route comparison (if on a known route)
                if let currentTrip = tripRecorder.currentTrip,
                   currentTrip.distanceMiles > 0.1,
                   let tracker = tripRecorder.locationTracker,
                   tracker.currentLatitude != 0 {
                    let currentLat = tracker.currentLatitude
                    let currentLon = tracker.currentLongitude
                    // Use trip's first GPS snapshot as route start, current position as end
                    let firstGPS = currentTrip.snapshots.first(where: { $0.latitude != nil })
                    let startLat = firstGPS?.latitude ?? currentLat
                    let startLon = firstGPS?.longitude ?? currentLon
                    if let matchedCluster = routeStore.matchingCluster(
                        startLat: startLat, startLon: startLon,
                        endLat: currentLat, endLon: currentLon
                    ) {
                        Section("Route") {
                            RouteComparisonView(
                                currentMPG: currentTrip.averageMPG,
                                cluster: matchedCluster
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }

                // Route navigation
                if !routeStore.clusters.isEmpty {
                    Section("Routes") {
                        NavigationLink {
                            RouteListView()
                        } label: {
                            HStack {
                                Label("My Routes", systemImage: "road.lanes")
                                Spacer()
                                Text("\(routeStore.clusters.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Live Tips") {
                    if analyzer.activeTips.isEmpty {
                        ContentUnavailableView(
                            "No Tips Yet",
                            systemImage: "checkmark.circle",
                            description: Text("You're driving efficiently! Tips will appear when there are opportunities to improve.")
                        )
                    } else {
                        ForEach(analyzer.activeTips) { tip in
                            CoachingTipRow(tip: tip)
                        }
                    }
                }
            }
            .navigationTitle("Coach")
        }
    }

    private var efficiencyScoreCard: some View {
        VStack(spacing: 12) {
            Text("Efficiency Score")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(analyzer.currentEfficiencyScore)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(scoreColor)
                .contentTransition(.numericText())
                .animation(.snappy, value: analyzer.currentEfficiencyScore)

            Text(scoreLabel)
                .font(.headline)
                .foregroundStyle(scoreColor)

            // Score bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)

                    Capsule()
                        .fill(scoreColor.gradient)
                        .frame(width: geo.size.width * Double(analyzer.currentEfficiencyScore) / 100.0, height: 8)
                        .animation(.easeInOut, value: analyzer.currentEfficiencyScore)
                }
            }
            .frame(height: 8)
        }
        .padding()
    }

    private var scoreColor: Color {
        switch analyzer.currentEfficiencyScore {
        case 90...100: .green
        case 70..<90: .blue
        case 50..<70: .orange
        default: .red
        }
    }

    private var scoreLabel: String {
        switch analyzer.currentEfficiencyScore {
        case 90...100: "Excellent"
        case 70..<90: "Good"
        case 50..<70: "Fair"
        default: "Needs Improvement"
        }
    }

    // MARK: - EV Goal Compact Card

    private var evGoalCompactCard: some View {
        let progress = evGoalStore.todayProgress(goalPercentage: settings.evGoalPercentage)

        return NavigationLink {
            EVGoalView()
        } label: {
            HStack(spacing: 12) {
                // Mini progress ring
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 4)
                        .frame(width: 44, height: 44)

                    Circle()
                        .trim(from: 0, to: min(progress.evPercent / 100.0, 1.0))
                        .stroke(
                            progress.goalMet ? Color.green.gradient : Color.blue.gradient,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))

                    Text(String(format: "%.0f%%", progress.evPercent))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's EV Goal")
                        .font(.subheadline)
                    Text(progress.goalMet ? "Goal met! 🎉" : "\(Int(settings.evGoalPercentage))% target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                let streak = evGoalStore.streak()
                if streak.currentStreak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                        Text("\(streak.currentStreak)")
                            .font(.subheadline.bold())
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
