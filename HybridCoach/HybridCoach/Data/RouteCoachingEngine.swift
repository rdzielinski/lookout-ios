import Foundation

/// Analyzes historical route data to generate route-specific coaching tips.
/// Detects hills, speed zones, sharp turns, and EV opportunity zones.
struct RouteCoachingEngine {

    // MARK: - Thresholds

    /// Minimum altitude change (meters) over a segment to flag as a hill.
    private static let hillAltitudeThreshold: Double = 10
    /// Distance (meters) to evaluate hill gradient over.
    private static let hillSegmentLength: Double = 200

    /// Bearing change (degrees) to flag as a sharp turn.
    private static let sharpTurnThreshold: Double = 60

    /// Minimum number of historical points where EV was active to flag an EV zone.
    private static let evZoneMinPoints: Int = 3

    // MARK: - Public

    /// Generate route-specific coaching tips by analyzing historical data for a cluster.
    static func generateTips(for cluster: RouteCluster, routes: [RouteRecord]) -> [RouteCoachingTip] {
        guard !routes.isEmpty else { return [] }

        var tips: [RouteCoachingTip] = []

        // Use the most recent route's polyline as the reference
        guard let referenceRoute = routes.sorted(by: { $0.date > $1.date }).first,
              referenceRoute.polyline.count > 2 else {
            return tips
        }

        let polyline = referenceRoute.polyline

        // Hill detection
        tips.append(contentsOf: detectHills(polyline: polyline))

        // Sharp turn detection
        tips.append(contentsOf: detectSharpTurns(polyline: polyline))

        // Speed zone detection (from historical data)
        tips.append(contentsOf: detectSpeedZones(routes: routes))

        // EV opportunity zones (from historical data)
        tips.append(contentsOf: detectEVZones(routes: routes))

        return tips
    }

    // MARK: - Hill Detection

    /// Detect uphill and downhill segments from altitude data.
    private static func detectHills(polyline: [RoutePoint]) -> [RouteCoachingTip] {
        var tips: [RouteCoachingTip] = []

        let stride = max(1, polyline.count / 20) // Sample ~20 segments
        var i = 0

        while i + stride < polyline.count {
            let start = polyline[i]
            let end = polyline[i + stride]

            guard let startAlt = start.altitude, let endAlt = end.altitude else {
                i += stride
                continue
            }

            let distance = haversineDistance(
                lat1: start.latitude, lon1: start.longitude,
                lat2: end.latitude, lon2: end.longitude
            )

            guard distance > 50 else {
                i += stride
                continue
            }

            let altChange = endAlt - startAlt

            if altChange > hillAltitudeThreshold {
                tips.append(RouteCoachingTip(
                    type: .hill,
                    message: "Uphill ahead — steady throttle",
                    detail: "Maintain consistent throttle pressure going uphill. Avoid flooring it; the hybrid system works best with gradual power delivery.",
                    coordinate: start.coordinate
                ))
            } else if altChange < -hillAltitudeThreshold {
                tips.append(RouteCoachingTip(
                    type: .hill,
                    message: "Downhill — lift for regen",
                    detail: "Ease off the throttle going downhill. Your RAV4 will recover energy through regenerative braking.",
                    coordinate: start.coordinate
                ))
            }

            i += stride
        }

        return tips
    }

    // MARK: - Sharp Turn Detection

    /// Detect sharp turns using bearing changes between consecutive segments.
    private static func detectSharpTurns(polyline: [RoutePoint]) -> [RouteCoachingTip] {
        var tips: [RouteCoachingTip] = []

        guard polyline.count >= 3 else { return tips }

        let stride = max(1, polyline.count / 30) // Sample ~30 points

        var i = stride
        while i + stride < polyline.count {
            let prev = polyline[i - stride]
            let curr = polyline[i]
            let next = polyline[i + stride]

            let bearing1 = bearing(from: prev, to: curr)
            let bearing2 = bearing(from: curr, to: next)

            var change = abs(bearing2 - bearing1)
            if change > 180 { change = 360 - change }

            if change > sharpTurnThreshold {
                tips.append(RouteCoachingTip(
                    type: .sharpTurn,
                    message: "Turn ahead — decelerate early",
                    detail: "Slow down gradually before the turn. Early deceleration captures more regenerative energy than hard braking at the last moment.",
                    coordinate: curr.coordinate
                ))
            }

            i += stride
        }

        // Limit to top 5 sharpest turns to avoid tip spam
        return Array(tips.prefix(5))
    }

    // MARK: - Speed Zone Detection

    /// Detect areas where historical speeds consistently drop (e.g., school zones, intersections).
    private static func detectSpeedZones(routes: [RouteRecord]) -> [RouteCoachingTip] {
        var tips: [RouteCoachingTip] = []

        // Need at least 2 routes with polylines
        let routesWithData = routes.filter { $0.polyline.count > 5 }
        guard routesWithData.count >= 2 else { return tips }

        // Sample the reference route and check if speeds consistently drop at certain points
        guard let reference = routesWithData.first else { return tips }
        let polyline = reference.polyline

        let stride = max(1, polyline.count / 15)
        var i = stride

        while i + stride < polyline.count {
            let curr = polyline[i]
            let prev = polyline[i - stride]

            guard let currSpeed = curr.speedMph, let prevSpeed = prev.speedMph else {
                i += stride
                continue
            }

            // Consistent speed drop of 15+ mph
            if prevSpeed - currSpeed > 15 && currSpeed < 40 {
                tips.append(RouteCoachingTip(
                    type: .speedZone,
                    message: "Slow zone — coast early for EV",
                    detail: "Speed drops in this area. Lift off the gas early to glide into the lower speed zone on electric power.",
                    coordinate: curr.coordinate
                ))
            }

            i += stride
        }

        return Array(tips.prefix(3))
    }

    // MARK: - EV Opportunity Zones

    /// Detect stretches where EV mode was historically active.
    private static func detectEVZones(routes: [RouteRecord]) -> [RouteCoachingTip] {
        // This is a simplified detection: look at the reference route's snapshots
        // In a real implementation, we'd overlay multiple routes' EV data spatially
        guard let reference = routes.sorted(by: { $0.date > $1.date }).first,
              reference.polyline.count > 5 else {
            return []
        }

        // If EV mode percentage is high for this route, note the opportunity
        if reference.evModePercentage > 30 {
            let midIdx = reference.polyline.count / 2
            let midPoint = reference.polyline[midIdx]

            return [RouteCoachingTip(
                type: .evOpportunity,
                message: "EV-friendly stretch",
                detail: "This route historically supports \(Int(reference.evModePercentage))% EV driving. Maintain gentle throttle to maximize electric-only operation.",
                coordinate: midPoint.coordinate
            )]
        }

        return []
    }

    // MARK: - Elevation Profile Builder

    /// Build an ElevationProfile from GPS altitude data recorded during a drive.
    static func buildElevationProfile(from polyline: [RoutePoint]) -> ElevationProfile? {
        let pointsWithAlt = polyline.filter { $0.altitude != nil }
        guard pointsWithAlt.count >= 2 else { return nil }

        var cumulativeDistance: Double = 0
        var totalAscent: Double = 0
        var totalDescent: Double = 0
        var minAlt = pointsWithAlt.first!.altitude!
        var maxAlt = pointsWithAlt.first!.altitude!

        var elevationPoints: [ElevationPoint] = []

        // First point
        elevationPoints.append(ElevationPoint(
            distanceFromStartMeters: 0,
            altitudeMeters: pointsWithAlt[0].altitude!,
            coordinate: CodableCoordinate(pointsWithAlt[0].coordinate)
        ))

        for i in 1..<pointsWithAlt.count {
            let prev = pointsWithAlt[i - 1]
            let curr = pointsWithAlt[i]

            let segDist = haversineDistance(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )
            cumulativeDistance += segDist

            let alt = curr.altitude!
            let prevAlt = prev.altitude!
            let altChange = alt - prevAlt

            if altChange > 0 { totalAscent += altChange }
            else { totalDescent += abs(altChange) }

            minAlt = min(minAlt, alt)
            maxAlt = max(maxAlt, alt)

            elevationPoints.append(ElevationPoint(
                distanceFromStartMeters: cumulativeDistance,
                altitudeMeters: alt,
                coordinate: CodableCoordinate(curr.coordinate)
            ))
        }

        return ElevationProfile(
            points: elevationPoints,
            totalAscentMeters: totalAscent,
            totalDescentMeters: totalDescent,
            maxAltitudeMeters: maxAlt,
            minAltitudeMeters: minAlt,
            source: .fromDrive
        )
    }

    // MARK: - Bearing Calculation

    /// Calculate bearing (degrees) from one point to another.
    private static func bearing(from p1: RoutePoint, to p2: RoutePoint) -> Double {
        let lat1 = p1.latitude * .pi / 180
        let lat2 = p2.latitude * .pi / 180
        let dLon = (p2.longitude - p1.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }
}
