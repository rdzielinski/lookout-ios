import SwiftUI

struct RouteListView: View {
    @Environment(RouteStore.self) var routeStore
    @Environment(PlannedRouteStore.self) var plannedRouteStore
    @State private var showPlanRoute = false

    var body: some View {
        List {
            // MARK: - Planned Routes
            if !plannedRouteStore.plannedRoutes.isEmpty {
                Section("Planned Routes") {
                    ForEach(plannedRouteStore.plannedRoutes) { route in
                        NavigationLink {
                            PlannedRouteAnalysisView(route: route)
                        } label: {
                            PlannedRouteRow(route: route)
                        }
                    }
                    .onDelete(perform: deletePlannedRoutes)
                }
            }

            // MARK: - Saved Routes
            if !routeStore.savedClusters.isEmpty {
                Section("Saved Routes") {
                    ForEach(routeStore.savedClusters) { cluster in
                        NavigationLink {
                            RouteDetailView(cluster: cluster)
                        } label: {
                            RouteClusterRow(cluster: cluster, showBookmark: true)
                        }
                    }
                }
            }

            // MARK: - Detected Routes
            if routeStore.clusters.isEmpty && plannedRouteStore.plannedRoutes.isEmpty {
                ContentUnavailableView(
                    "No Routes Yet",
                    systemImage: "road.lanes",
                    description: Text("Tap + to plan a route, or drive a few trips and HybridCoach will automatically detect your common routes.")
                )
            } else if !routeStore.unsavedClusters.isEmpty {
                Section("Detected Routes") {
                    ForEach(routeStore.unsavedClusters) { cluster in
                        NavigationLink {
                            RouteDetailView(cluster: cluster)
                        } label: {
                            RouteClusterRow(cluster: cluster)
                        }
                    }
                }
            }

            if !routeStore.clusters.isEmpty {
                Section {
                    HStack {
                        Text("Total Routes")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(routeStore.clusters.count)")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Total Trips Tracked")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(routeStore.routes.count)")
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Routes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPlanRoute = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showPlanRoute) {
            PlannedRouteEntryView()
        }
    }

    private func deletePlannedRoutes(at offsets: IndexSet) {
        for index in offsets {
            let route = plannedRouteStore.plannedRoutes[index]
            plannedRouteStore.deleteRoute(id: route.id)
        }
    }
}

// MARK: - Planned Route Row

private struct PlannedRouteRow: View {
    let route: PlannedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(route.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if route.elevationProfile != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Label(String(format: "%.1f mi", route.distanceMiles), systemImage: "road.lanes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(formatDuration(route.expectedTravelTimeSeconds), systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !route.preAnalysisTips.isEmpty {
                    Label("\(route.preAnalysisTips.count) tips", systemImage: "lightbulb")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}

// MARK: - Cluster Row

private struct RouteClusterRow: View {
    let cluster: RouteCluster
    var showBookmark: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showBookmark {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Text(cluster.displayName)
                    .font(.headline)

                Spacer()

                Text("\(cluster.tripCount) trips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label(String(format: "%.1f MPG", cluster.averageMPG), systemImage: "fuelpump")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Label("\(cluster.averageEfficiency)/100", systemImage: "star")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if cluster.bestMPG > 0 {
                    Label(String(format: "Best: %.1f", cluster.bestMPG), systemImage: "trophy")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
