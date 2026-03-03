import Foundation

/// Persists route records and clusters, auto-grouping similar routes.
@MainActor
@Observable
final class RouteStore {

    private(set) var routes: [RouteRecord] = []
    private(set) var clusters: [RouteCluster] = []

    private let routesURL: URL
    private let clustersURL: URL

    /// Distance threshold for clustering start/end points (meters).
    private let clusterThreshold: Double = 500

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        routesURL = docs.appendingPathComponent("routes.json")
        clustersURL = docs.appendingPathComponent("route_clusters.json")
        load()
    }

    // MARK: - Add Route

    func addRoute(_ route: RouteRecord) {
        routes.append(route)

        // Try to find an existing cluster
        if let idx = findMatchingCluster(for: route) {
            clusters[idx].addRoute(route)
        } else {
            // Create new cluster
            let cluster = RouteCluster(firstRoute: route)
            clusters.append(cluster)
        }

        save()
    }

    // MARK: - Clustering

    /// Find a cluster whose anchor start/end are within threshold of the route.
    private func findMatchingCluster(for route: RouteRecord) -> Int? {
        for (i, cluster) in clusters.enumerated() {
            let startDist = haversineDistance(
                lat1: cluster.anchorStart.latitude,
                lon1: cluster.anchorStart.longitude,
                lat2: route.startCoordinate.latitude,
                lon2: route.startCoordinate.longitude
            )
            let endDist = haversineDistance(
                lat1: cluster.anchorEnd.latitude,
                lon1: cluster.anchorEnd.longitude,
                lat2: route.endCoordinate.latitude,
                lon2: route.endCoordinate.longitude
            )

            if startDist <= clusterThreshold && endDist <= clusterThreshold {
                return i
            }
        }
        return nil
    }

    // MARK: - Saved / Unsaved Clusters

    /// Clusters the user has bookmarked.
    var savedClusters: [RouteCluster] {
        clusters.filter { $0.isSaved }
    }

    /// Clusters that haven't been bookmarked.
    var unsavedClusters: [RouteCluster] {
        clusters.filter { !$0.isSaved }
    }

    /// Toggle the saved/bookmarked state of a cluster.
    func toggleSaved(id: UUID) {
        if let idx = clusters.firstIndex(where: { $0.id == id }) {
            clusters[idx].isSaved.toggle()
            save()
        }
    }

    /// Convert a detected route cluster into a PlannedRoute for pre-analysis.
    func convertToPlannedRoute(clusterID: UUID, plannedRouteStore: PlannedRouteStore?) {
        guard let plannedRouteStore else { return }
        guard let cluster = clusters.first(where: { $0.id == clusterID }) else { return }

        // Check if already linked to avoid duplicates
        let alreadyLinked = plannedRouteStore.plannedRoutes.contains {
            $0.linkedClusterID == clusterID
        }
        guard !alreadyLinked else { return }

        // Use the most recent route record for polyline/distance data
        let clusterRoutes = routes(for: cluster)
        guard let mostRecent = clusterRoutes.sorted(by: { $0.date > $1.date }).first else { return }

        // Build data from the driven route
        let polyline = mostRecent.polyline.map { CodableCoordinate($0.coordinate) }
        let elevationProfile = RouteCoachingEngine.buildElevationProfile(from: mostRecent.polyline)
        let speedLimitProfile = buildSpeedLimitProfile(from: mostRecent.polyline)

        // Generate coaching tips from the cluster
        let coachingTips = RouteCoachingEngine.generateTips(for: cluster, routes: clusterRoutes)
        let plannedTips = coachingTips.map { tip in
            PlannedRouteTip(
                id: UUID(),
                type: mapTipType(tip.type),
                message: tip.message,
                detail: tip.detail,
                coordinate: tip.coordinate.map { CodableCoordinate($0) },
                distanceFromStartMeters: nil
            )
        }

        let planned = PlannedRoute(
            id: UUID(),
            name: cluster.displayName,
            createdDate: Date(),
            startAddress: "Detected Start",
            endAddress: "Detected End",
            startCoordinate: CodableCoordinate(cluster.anchorStart.coordinate),
            endCoordinate: CodableCoordinate(cluster.anchorEnd.coordinate),
            polyline: polyline,
            distanceMiles: mostRecent.distanceMiles,
            expectedTravelTimeSeconds: 0,
            expectedTravelTimeWithTrafficSeconds: nil,
            steps: [],
            elevationProfile: elevationProfile,
            speedLimitProfile: speedLimitProfile.segments.isEmpty ? nil : speedLimitProfile,
            surfaceProfile: nil,
            trafficSummary: nil,
            preAnalysisTips: plannedTips,
            linkedClusterID: clusterID
        )

        plannedRouteStore.addRoute(planned)
    }

    /// Map RouteCoachingTip.TipType to PlannedRouteTip.TipType.
    private func mapTipType(_ type: RouteCoachingTip.TipType) -> PlannedRouteTip.TipType {
        switch type {
        case .hill: .hill
        case .speedZone: .speedZone
        case .sharpTurn: .sharpTurn
        case .evOpportunity: .evOpportunity
        }
    }

    // MARK: - Queries

    /// Get all routes belonging to a cluster.
    func routes(for cluster: RouteCluster) -> [RouteRecord] {
        let idSet = Set(cluster.routeRecordIDs)
        return routes.filter { idSet.contains($0.id) }
    }

    /// Find which cluster (if any) the current trip start/end matches.
    func matchingCluster(startLat: Double, startLon: Double,
                         endLat: Double, endLon: Double) -> RouteCluster? {
        for cluster in clusters {
            let startDist = haversineDistance(
                lat1: cluster.anchorStart.latitude,
                lon1: cluster.anchorStart.longitude,
                lat2: startLat, lon2: startLon
            )
            let endDist = haversineDistance(
                lat1: cluster.anchorEnd.latitude,
                lon1: cluster.anchorEnd.longitude,
                lat2: endLat, lon2: endLon
            )
            if startDist <= clusterThreshold && endDist <= clusterThreshold {
                return cluster
            }
        }
        return nil
    }

    /// Compare current trip's MPG against a cluster's average.
    func comparison(currentMPG: Double, cluster: RouteCluster) -> (delta: Double, percentChange: Double) {
        let delta = currentMPG - cluster.averageMPG
        let pct = cluster.averageMPG > 0 ? (delta / cluster.averageMPG) * 100 : 0
        return (delta, pct)
    }

    /// Rename a cluster.
    func renameCluster(id: UUID, name: String) {
        if let idx = clusters.firstIndex(where: { $0.id == id }) {
            clusters[idx].name = name
            save()
        }
    }

    // MARK: - Planned Route Backfill

    /// After a drive completes, check if it matches any planned route and backfill data.
    func backfillPlannedRouteData(routeRecord: RouteRecord, plannedRouteStore: PlannedRouteStore?) {
        guard let plannedRouteStore else { return }

        for planned in plannedRouteStore.plannedRoutes {
            // Check if the driven route matches this planned route (start + end within threshold)
            let startDist = haversineDistance(
                lat1: planned.startCoordinate.latitude,
                lon1: planned.startCoordinate.longitude,
                lat2: routeRecord.startCoordinate.latitude,
                lon2: routeRecord.startCoordinate.longitude
            )
            let endDist = haversineDistance(
                lat1: planned.endCoordinate.latitude,
                lon1: planned.endCoordinate.longitude,
                lat2: routeRecord.endCoordinate.latitude,
                lon2: routeRecord.endCoordinate.longitude
            )

            if startDist <= clusterThreshold && endDist <= clusterThreshold {
                // Backfill elevation if pending
                if planned.elevationProfile == nil {
                    if let profile = RouteCoachingEngine.buildElevationProfile(from: routeRecord.polyline) {
                        plannedRouteStore.updateElevation(routeID: planned.id, profile: profile)
                    }
                }

                // Backfill speed limits
                if planned.speedLimitProfile == nil {
                    let profile = buildSpeedLimitProfile(from: routeRecord.polyline)
                    if !profile.segments.isEmpty {
                        plannedRouteStore.updateSpeedLimits(routeID: planned.id, profile: profile)
                    }
                }

                // Link to cluster if not already linked
                if planned.linkedClusterID == nil {
                    if let cluster = findMatchingCluster(for: routeRecord) {
                        plannedRouteStore.linkToCluster(plannedRouteID: planned.id, clusterID: clusters[cluster].id)
                    }
                }

                break // Only match one planned route
            }
        }
    }

    /// Build a speed limit profile by inferring posted limits from observed OBD speeds.
    private func buildSpeedLimitProfile(from polyline: [RoutePoint]) -> SpeedLimitProfile {
        let pointsWithSpeed = polyline.filter { $0.speedMph != nil }
        guard pointsWithSpeed.count >= 5 else {
            return SpeedLimitProfile(segments: [], source: .learnedFromDriving)
        }

        // Common US posted speed limits
        let postedLimits: [Double] = [15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75]

        // Group polyline into ~500m segments
        let segmentLength: Double = 500
        var segments: [SpeedLimitSegment] = []
        var cumulativeDistance: Double = 0
        var segmentStartDist: Double = 0
        var segmentSpeeds: [Double] = []
        var segmentCoord = pointsWithSpeed.first!

        for i in 1..<pointsWithSpeed.count {
            let prev = pointsWithSpeed[i - 1]
            let curr = pointsWithSpeed[i]

            let dist = haversineDistance(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )
            cumulativeDistance += dist

            if let speed = curr.speedMph {
                segmentSpeeds.append(speed)
            }

            if cumulativeDistance - segmentStartDist >= segmentLength && !segmentSpeeds.isEmpty {
                // Round the ~85th percentile speed to the nearest posted limit
                let sorted = segmentSpeeds.sorted()
                let p85Idx = min(Int(Double(sorted.count) * 0.85), sorted.count - 1)
                let observedMax = sorted[p85Idx]

                let nearest = postedLimits.min(by: { abs($0 - observedMax) < abs($1 - observedMax) })

                segments.append(SpeedLimitSegment(
                    startDistanceMeters: segmentStartDist,
                    endDistanceMeters: cumulativeDistance,
                    estimatedSpeedLimitMph: nearest,
                    coordinate: CodableCoordinate(curr.coordinate)
                ))

                segmentStartDist = cumulativeDistance
                segmentSpeeds = []
                segmentCoord = curr
            }
        }

        return SpeedLimitProfile(segments: segments, source: .learnedFromDriving)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let routeData = try JSONEncoder().encode(routes)
            try routeData.write(to: routesURL, options: .atomic)

            let clusterData = try JSONEncoder().encode(clusters)
            try clusterData.write(to: clustersURL, options: .atomic)
        } catch {
            print("RouteStore: Failed to save — \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            let routeData = try Data(contentsOf: routesURL)
            routes = try JSONDecoder().decode([RouteRecord].self, from: routeData)
        } catch {
            routes = []
        }

        do {
            let clusterData = try Data(contentsOf: clustersURL)
            clusters = try JSONDecoder().decode([RouteCluster].self, from: clusterData)
        } catch {
            clusters = []
        }
    }
}
