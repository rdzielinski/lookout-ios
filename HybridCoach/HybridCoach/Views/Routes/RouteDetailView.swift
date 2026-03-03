import SwiftUI
import Charts

struct RouteDetailView: View {
    let cluster: RouteCluster
    @Environment(RouteStore.self) var routeStore
    @Environment(PlannedRouteStore.self) var plannedRouteStore
    @Environment(TripRecorder.self) var tripRecorder
    @State private var isRenaming = false
    @State private var newName = ""

    /// Live cluster lookup so the view refreshes after toggleSaved / rename.
    private var liveCluster: RouteCluster {
        routeStore.clusters.first(where: { $0.id == cluster.id }) ?? cluster
    }

    private var routeRecords: [RouteRecord] {
        routeStore.routes(for: liveCluster)
    }

    private var coachingTips: [RouteCoachingTip] {
        RouteCoachingEngine.generateTips(for: liveCluster, routes: routeRecords)
    }

    /// Whether this cluster is already linked to a planned route.
    private var isLinkedToPlannedRoute: Bool {
        plannedRouteStore.plannedRoutes.contains { $0.linkedClusterID == liveCluster.id }
    }

    var body: some View {
        List {
            // Map Section
            if let latestRoute = routeRecords.sorted(by: { $0.date > $1.date }).first,
               latestRoute.polyline.count > 1 {
                Section("Route Map") {
                    RouteMapView(polyline: latestRoute.polyline)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            // Stats
            Section("Route Statistics") {
                HStack {
                    Label("Average MPG", systemImage: "fuelpump")
                    Spacer()
                    Text(String(format: "%.1f", liveCluster.averageMPG))
                        .monospacedDigit()
                        .bold()
                }

                HStack {
                    Label("Best MPG", systemImage: "trophy")
                    Spacer()
                    Text(String(format: "%.1f", liveCluster.bestMPG))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }

                HStack {
                    Label("Avg Efficiency", systemImage: "star")
                    Spacer()
                    Text("\(liveCluster.averageEfficiency)/100")
                        .monospacedDigit()
                }

                HStack {
                    Label("Trips Recorded", systemImage: "car")
                    Spacer()
                    Text("\(liveCluster.tripCount)")
                        .monospacedDigit()
                }
            }

            // MPG History Chart
            if routeRecords.count >= 2 {
                Section("MPG History") {
                    Chart(routeRecords.sorted(by: { $0.date < $1.date })) { route in
                        LineMark(
                            x: .value("Trip", route.date),
                            y: .value("MPG", route.averageMPG)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.blue)

                        PointMark(
                            x: .value("Trip", route.date),
                            y: .value("MPG", route.averageMPG)
                        )
                        .foregroundStyle(.blue)

                        RuleMark(y: .value("Average", liveCluster.averageMPG))
                            .foregroundStyle(.green.opacity(0.5))
                            .lineStyle(StrokeStyle(dash: [5, 3]))
                    }
                    .chartYAxisLabel("MPG")
                    .frame(height: 180)
                }
            }

            // Route Coaching Tips
            if !coachingTips.isEmpty {
                Section("Route-Specific Tips") {
                    ForEach(coachingTips) { tip in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: iconForTipType(tip.type))
                                    .foregroundStyle(colorForTipType(tip.type))
                                Text(tip.message)
                                    .font(.subheadline.bold())
                            }
                            Text(tip.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Save as Planned Route
            if !isLinkedToPlannedRoute {
                Section {
                    Button {
                        routeStore.convertToPlannedRoute(
                            clusterID: liveCluster.id,
                            plannedRouteStore: plannedRouteStore
                        )
                    } label: {
                        Label("Save as Planned Route", systemImage: "map")
                    }
                } footer: {
                    Text("Creates a planned route from this detected route for pre-drive analysis.")
                }
            }

            // Trip History — tappable rows link to improvement map
            Section("Recent Trips") {
                ForEach(routeRecords.sorted(by: { $0.date > $1.date }).prefix(10), id: \.id) { route in
                    if route.polyline.count >= 2 {
                        NavigationLink {
                            TripImprovementMapView(
                                trip: tripForRouteRecord(route),
                                routeRecord: route
                            )
                        } label: {
                            tripRowContent(route: route)
                        }
                    } else {
                        tripRowContent(route: route)
                    }
                }
            }

            // Rename
            Section {
                Button {
                    newName = liveCluster.name ?? ""
                    isRenaming = true
                } label: {
                    Label("Rename Route", systemImage: "pencil")
                }
            }
        }
        .navigationTitle(liveCluster.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    routeStore.toggleSaved(id: liveCluster.id)
                } label: {
                    Image(systemName: liveCluster.isSaved ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .alert("Rename Route", isPresented: $isRenaming) {
            TextField("Route name", text: $newName)
            Button("Save") {
                routeStore.renameCluster(id: liveCluster.id, name: newName)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a name for this route (e.g., \"Morning Commute\").")
        }
    }

    // MARK: - Trip Row Content

    private func tripRowContent(route: RouteRecord) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(route.date, style: .date)
                    .font(.subheadline)
                Text(route.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(String(format: "%.1f MPG", route.averageMPG))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text(String(format: "%.1f mi", route.distanceMiles))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Look up the real Trip from TripRecorder that matches this route record.
    private func tripForRouteRecord(_ record: RouteRecord) -> Trip {
        tripRecorder.pastTrips.first(where: { $0.id == record.tripID }) ?? Trip()
    }

    // MARK: - Helpers

    private func iconForTipType(_ type: RouteCoachingTip.TipType) -> String {
        switch type {
        case .hill: "mountain.2"
        case .speedZone: "speedometer"
        case .sharpTurn: "arrow.turn.right.up"
        case .evOpportunity: "bolt.fill"
        }
    }

    private func colorForTipType(_ type: RouteCoachingTip.TipType) -> Color {
        switch type {
        case .hill: .brown
        case .speedZone: .orange
        case .sharpTurn: .red
        case .evOpportunity: .green
        }
    }
}
