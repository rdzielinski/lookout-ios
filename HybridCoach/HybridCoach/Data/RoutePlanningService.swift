import Foundation
import MapKit

/// Converts user input (addresses or coordinates) into a PlannedRoute
/// using MKDirections and performs initial pre-analysis on the polyline.
struct RoutePlanningService {

    enum PlanningError: LocalizedError {
        case noRouteFound
        case geocodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRouteFound:
                "No driving route found between those locations."
            case .geocodingFailed(let address):
                "Could not find address: \(address)"
            }
        }
    }

    // MARK: - Public API

    /// Plan a route between two street addresses.
    static func planRoute(
        from startAddress: String,
        to endAddress: String,
        departureDate: Date? = nil
    ) async throws -> PlannedRoute {
        let geocoder = CLGeocoder()

        let startPlacemarks = try await geocoder.geocodeAddressString(startAddress)
        guard let startLocation = startPlacemarks.first?.location else {
            throw PlanningError.geocodingFailed(startAddress)
        }

        let endPlacemarks = try await geocoder.geocodeAddressString(endAddress)
        guard let endLocation = endPlacemarks.first?.location else {
            throw PlanningError.geocodingFailed(endAddress)
        }

        return try await planRoute(
            startCoordinate: startLocation.coordinate,
            endCoordinate: endLocation.coordinate,
            startAddress: startAddress,
            endAddress: endAddress,
            departureDate: departureDate
        )
    }

    /// Plan a route between two coordinates.
    static func planRoute(
        startCoordinate: CLLocationCoordinate2D,
        endCoordinate: CLLocationCoordinate2D,
        startAddress: String = "",
        endAddress: String = "",
        departureDate: Date? = nil
    ) async throws -> PlannedRoute {
        // 1. Request driving directions from MapKit
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: startCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: endCoordinate))
        request.transportType = .automobile
        if let departure = departureDate {
            request.departureDate = departure
        }

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        guard let mkRoute = response.routes.first else {
            throw PlanningError.noRouteFound
        }

        // 2. Sample the polyline coordinates
        let polylineCoords = samplePolyline(mkRoute.polyline, maxPoints: 200)

        // 3. Extract turn-by-turn steps
        let steps = mkRoute.steps.compactMap { step -> PlannedRouteStep? in
            guard !step.instructions.isEmpty else { return nil }
            return PlannedRouteStep(
                id: UUID(),
                instructions: step.instructions,
                distanceMeters: step.distance,
                coordinate: CodableCoordinate(step.polyline.coordinate)
            )
        }

        // 4. Build traffic summary
        let trafficSummary = TrafficSummary(
            queriedAt: Date(),
            departureDate: departureDate,
            expectedMinutes: mkRoute.expectedTravelTime / 60.0,
            trafficAwareMinutes: departureDate != nil ? mkRoute.expectedTravelTime / 60.0 : nil,
            trafficCondition: classifyTraffic(mkRoute)
        )

        // 5. Generate initial pre-analysis tips
        let tips = generateInitialTips(polyline: polylineCoords)

        // 6. Assemble the PlannedRoute
        return PlannedRoute(
            id: UUID(),
            name: "",
            createdDate: Date(),
            startAddress: startAddress,
            endAddress: endAddress,
            startCoordinate: CodableCoordinate(startCoordinate),
            endCoordinate: CodableCoordinate(endCoordinate),
            polyline: polylineCoords,
            distanceMiles: mkRoute.distance / 1609.344,
            expectedTravelTimeSeconds: mkRoute.expectedTravelTime,
            expectedTravelTimeWithTrafficSeconds: departureDate != nil ? mkRoute.expectedTravelTime : nil,
            steps: steps,
            elevationProfile: nil,
            speedLimitProfile: nil,
            surfaceProfile: nil,
            trafficSummary: trafficSummary,
            preAnalysisTips: tips,
            linkedClusterID: nil
        )
    }

    // MARK: - Polyline Sampling

    /// Extract coordinate points from an MKPolyline, sampling evenly if too many.
    private static func samplePolyline(_ polyline: MKPolyline, maxPoints: Int) -> [CodableCoordinate] {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return [] }

        let coords = UnsafeMutablePointer<CLLocationCoordinate2D>.allocate(capacity: pointCount)
        defer { coords.deallocate() }
        polyline.getCoordinates(coords, range: NSRange(location: 0, length: pointCount))

        if pointCount <= maxPoints {
            return (0..<pointCount).map { CodableCoordinate(coords[$0]) }
        }

        // Sample evenly across the polyline
        let strideValue = Double(pointCount - 1) / Double(maxPoints - 1)
        var result: [CodableCoordinate] = []
        result.reserveCapacity(maxPoints)
        for i in 0..<maxPoints {
            let idx = min(Int(Double(i) * strideValue), pointCount - 1)
            result.append(CodableCoordinate(coords[idx]))
        }
        return result
    }

    // MARK: - Traffic Classification

    private static func classifyTraffic(_ route: MKRoute) -> TrafficSummary.TrafficCondition {
        // Compare actual ETA vs ideal time at ~50 mph
        let idealSpeedMps = 22.352  // 50 mph in m/s
        let idealTime = route.distance / idealSpeedMps
        guard idealTime > 0 else { return .unknown }

        let ratio = route.expectedTravelTime / idealTime
        if ratio < 1.2 { return .light }
        if ratio < 1.6 { return .moderate }
        if ratio < 2.5 { return .heavy }
        return .unknown
    }

    // MARK: - Initial Pre-analysis

    private static func generateInitialTips(polyline: [CodableCoordinate]) -> [PlannedRouteTip] {
        var tips: [PlannedRouteTip] = []
        tips.append(contentsOf: detectSharpTurns(polyline: polyline))
        tips.append(contentsOf: detectLongStraights(polyline: polyline))
        return tips
    }

    /// Detect sharp turns (>60° bearing change) from the polyline.
    private static func detectSharpTurns(polyline: [CodableCoordinate]) -> [PlannedRouteTip] {
        guard polyline.count >= 3 else { return [] }
        var tips: [PlannedRouteTip] = []
        let step = max(1, polyline.count / 30)
        var i = step

        while i + step < polyline.count {
            let prev = polyline[i - step]
            let curr = polyline[i]
            let next = polyline[i + step]

            let b1 = bearing(from: prev, to: curr)
            let b2 = bearing(from: curr, to: next)
            var change = abs(b2 - b1)
            if change > 180 { change = 360 - change }

            if change > 60 {
                tips.append(PlannedRouteTip(
                    id: UUID(),
                    type: .sharpTurn,
                    message: "Sharp turn ahead — decelerate early for regen",
                    detail: "Slow down gradually before this turn. Early braking captures more regenerative energy in the hybrid system.",
                    coordinate: curr,
                    distanceFromStartMeters: nil
                ))
            }
            i += step
        }
        return Array(tips.prefix(5))
    }

    /// Detect long straight segments (>800 m) that are potential EV zones.
    private static func detectLongStraights(polyline: [CodableCoordinate]) -> [PlannedRouteTip] {
        guard polyline.count >= 10 else { return [] }
        var tips: [PlannedRouteTip] = []
        let segmentSize = max(1, polyline.count / 10)

        for i in stride(from: 0, to: polyline.count - segmentSize, by: segmentSize) {
            let start = polyline[i]
            let end = polyline[min(i + segmentSize, polyline.count - 1)]

            let dist = haversineDistance(
                lat1: start.latitude, lon1: start.longitude,
                lat2: end.latitude, lon2: end.longitude
            )

            if dist > 800 {
                tips.append(PlannedRouteTip(
                    id: UUID(),
                    type: .longStraight,
                    message: "Long straight — potential EV zone",
                    detail: "Straight road segments at moderate speed are ideal for EV-only driving. Keep the throttle gentle to maximize electric range.",
                    coordinate: start,
                    distanceFromStartMeters: nil
                ))
            }
        }
        return Array(tips.prefix(3))
    }

    // MARK: - Bearing Utility

    /// Compass bearing in degrees (0-360) from point A to point B.
    private static func bearing(from p1: CodableCoordinate, to p2: CodableCoordinate) -> Double {
        let lat1 = p1.latitude * .pi / 180
        let lat2 = p2.latitude * .pi / 180
        let dLon = (p2.longitude - p1.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var result = atan2(y, x) * 180 / .pi
        if result < 0 { result += 360 }
        return result
    }
}
