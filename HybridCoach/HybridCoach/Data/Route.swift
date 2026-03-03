import Foundation
import CoreLocation

// MARK: - Route Point

/// A single GPS point recorded during a trip.
struct RoutePoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let timestamp: Date
    let speedMph: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Route Record

/// A complete GPS trace for one trip, with associated efficiency data.
struct RouteRecord: Identifiable, Codable {
    let id: UUID
    let tripID: UUID
    let startCoordinate: RoutePoint
    let endCoordinate: RoutePoint
    let polyline: [RoutePoint]
    let distanceMiles: Double
    let averageMPG: Double
    let evModePercentage: Double
    let efficiencyScore: Int
    let date: Date
}

// MARK: - Route Cluster

/// A group of similar routes (same start/end area) for comparison.
struct RouteCluster: Identifiable, Codable {
    let id: UUID
    var name: String?
    let anchorStart: RoutePoint
    let anchorEnd: RoutePoint
    var routeRecordIDs: [UUID]
    var averageMPG: Double
    var averageEfficiency: Int
    var bestMPG: Double
    var tripCount: Int
    var isSaved: Bool

    // Backward-compatible decoding: old JSON won't have isSaved
    enum CodingKeys: String, CodingKey {
        case id, name, anchorStart, anchorEnd, routeRecordIDs
        case averageMPG, averageEfficiency, bestMPG, tripCount, isSaved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        anchorStart = try container.decode(RoutePoint.self, forKey: .anchorStart)
        anchorEnd = try container.decode(RoutePoint.self, forKey: .anchorEnd)
        routeRecordIDs = try container.decode([UUID].self, forKey: .routeRecordIDs)
        averageMPG = try container.decode(Double.self, forKey: .averageMPG)
        averageEfficiency = try container.decode(Int.self, forKey: .averageEfficiency)
        bestMPG = try container.decode(Double.self, forKey: .bestMPG)
        tripCount = try container.decode(Int.self, forKey: .tripCount)
        isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
    }

    init(name: String? = nil, firstRoute: RouteRecord) {
        self.id = UUID()
        self.name = name
        self.anchorStart = firstRoute.startCoordinate
        self.anchorEnd = firstRoute.endCoordinate
        self.routeRecordIDs = [firstRoute.id]
        self.averageMPG = firstRoute.averageMPG
        self.averageEfficiency = firstRoute.efficiencyScore
        self.bestMPG = firstRoute.averageMPG
        self.tripCount = 1
        self.isSaved = false
    }

    /// Update cluster averages after adding a new route.
    mutating func addRoute(_ route: RouteRecord) {
        routeRecordIDs.append(route.id)
        tripCount += 1
        bestMPG = max(bestMPG, route.averageMPG)

        // Running average
        let totalMPG = averageMPG * Double(tripCount - 1) + route.averageMPG
        averageMPG = totalMPG / Double(tripCount)

        let totalScore = Double(averageEfficiency * (tripCount - 1)) + Double(route.efficiencyScore)
        averageEfficiency = Int(totalScore / Double(tripCount))
    }

    var displayName: String {
        name ?? "Route #\(id.uuidString.prefix(4))"
    }
}

// MARK: - Route Coaching Tip

/// A location-specific driving tip generated from route analysis.
struct RouteCoachingTip: Identifiable {
    let id = UUID()
    let type: TipType
    let message: String
    let detail: String
    let coordinate: CLLocationCoordinate2D?

    enum TipType: String {
        case hill = "Hill"
        case speedZone = "Speed Zone"
        case sharpTurn = "Turn"
        case evOpportunity = "EV Zone"
    }
}

// MARK: - Haversine Distance

/// Utility: Compute great-circle distance between two coordinates in meters.
func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6371000.0 // Earth radius in meters
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
            sin(dLon / 2) * sin(dLon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c
}
