import Foundation

/// Stores user-created planned routes and manages their progressive analysis data.
@MainActor
@Observable
final class PlannedRouteStore {

    private(set) var plannedRoutes: [PlannedRoute] = []
    private let storageURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("planned_routes.json")
        load()
    }

    // MARK: - CRUD

    func addRoute(_ route: PlannedRoute) {
        plannedRoutes.insert(route, at: 0)
        save()
    }

    func deleteRoute(id: UUID) {
        plannedRoutes.removeAll { $0.id == id }
        save()
    }

    func renameRoute(id: UUID, name: String) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == id }) else { return }
        plannedRoutes[idx].name = name
        save()
    }

    func updateRoute(_ route: PlannedRoute) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == route.id }) else { return }
        plannedRoutes[idx] = route
        save()
    }

    // MARK: - Learning Updates

    /// Link a planned route to an actual driven route cluster.
    func linkToCluster(plannedRouteID: UUID, clusterID: UUID) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == plannedRouteID }) else { return }
        plannedRoutes[idx].linkedClusterID = clusterID
        save()
    }

    /// Update elevation profile from a completed drive's GPS altitude data.
    func updateElevation(routeID: UUID, profile: ElevationProfile) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == routeID }) else { return }
        plannedRoutes[idx].elevationProfile = profile
        save()
    }

    /// Update speed limit data learned from driving.
    func updateSpeedLimits(routeID: UUID, profile: SpeedLimitProfile) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == routeID }) else { return }
        plannedRoutes[idx].speedLimitProfile = profile
        save()
    }

    /// Update traffic summary with a fresh query.
    func updateTraffic(routeID: UUID, summary: TrafficSummary) {
        guard let idx = plannedRoutes.firstIndex(where: { $0.id == routeID }) else { return }
        plannedRoutes[idx].trafficSummary = summary
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(plannedRoutes)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("PlannedRouteStore: Failed to save — \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            plannedRoutes = []
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            plannedRoutes = try JSONDecoder().decode([PlannedRoute].self, from: data)
        } catch {
            print("PlannedRouteStore: Failed to load — \(error.localizedDescription)")
            plannedRoutes = []
        }
    }
}
