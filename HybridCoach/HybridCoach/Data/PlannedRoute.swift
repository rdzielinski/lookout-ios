import Foundation
import CoreLocation

// MARK: - Codable Coordinate

/// Lightweight Codable wrapper for CLLocationCoordinate2D.
struct CodableCoordinate: Codable, Sendable, Hashable {
    let latitude: Double
    let longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

// MARK: - Planned Route

/// A route that was manually planned (not yet driven or driven later).
struct PlannedRoute: Identifiable, Codable {
    let id: UUID
    var name: String
    let createdDate: Date

    // Endpoints
    let startAddress: String
    let endAddress: String
    let startCoordinate: CodableCoordinate
    let endCoordinate: CodableCoordinate

    // MKDirections-derived data
    let polyline: [CodableCoordinate]
    let distanceMiles: Double
    let expectedTravelTimeSeconds: Double
    let expectedTravelTimeWithTrafficSeconds: Double?
    let steps: [PlannedRouteStep]

    // Pre-analysis data (populated progressively)
    var elevationProfile: ElevationProfile?
    var speedLimitProfile: SpeedLimitProfile?
    var surfaceProfile: SurfaceProfile?
    var trafficSummary: TrafficSummary?

    // Coaching pre-analysis
    var preAnalysisTips: [PlannedRouteTip]

    // Link to actual driven route cluster
    var linkedClusterID: UUID?

    var displayName: String {
        if !name.isEmpty { return name }
        let start = startAddress.prefix(25)
        let end = endAddress.prefix(25)
        return "\(start) → \(end)"
    }
}

// MARK: - Route Step

/// A single turn-by-turn instruction from MKRoute.
struct PlannedRouteStep: Codable, Identifiable {
    let id: UUID
    let instructions: String
    let distanceMeters: Double
    let coordinate: CodableCoordinate
}

// MARK: - Elevation Profile

struct ElevationProfile: Codable {
    let points: [ElevationPoint]
    let totalAscentMeters: Double
    let totalDescentMeters: Double
    let maxAltitudeMeters: Double
    let minAltitudeMeters: Double
    let source: ElevationSource

    enum ElevationSource: String, Codable {
        case fromDrive
        case estimated
        case unknown
    }
}

struct ElevationPoint: Codable {
    let distanceFromStartMeters: Double
    let altitudeMeters: Double
    let coordinate: CodableCoordinate
}

// MARK: - Speed Limit Profile

struct SpeedLimitProfile: Codable {
    let segments: [SpeedLimitSegment]
    let source: SpeedLimitSource

    enum SpeedLimitSource: String, Codable {
        case learnedFromDriving
        case unknown
    }
}

struct SpeedLimitSegment: Codable {
    let startDistanceMeters: Double
    let endDistanceMeters: Double
    let estimatedSpeedLimitMph: Double?
    let coordinate: CodableCoordinate
}

// MARK: - Surface Profile

struct SurfaceProfile: Codable {
    let segments: [SurfaceSegment]
}

struct SurfaceSegment: Codable {
    let startDistanceMeters: Double
    let endDistanceMeters: Double
    let surfaceType: SurfaceType

    enum SurfaceType: String, Codable {
        case paved
        case gravel
        case dirt
        case unknown
    }
}

// MARK: - Traffic Summary

struct TrafficSummary: Codable {
    let queriedAt: Date
    let departureDate: Date?
    let expectedMinutes: Double
    let trafficAwareMinutes: Double?
    let trafficCondition: TrafficCondition

    enum TrafficCondition: String, Codable {
        case light
        case moderate
        case heavy
        case unknown
    }
}

// MARK: - Pre-analysis Tip

struct PlannedRouteTip: Identifiable, Codable {
    let id: UUID
    let type: TipType
    let message: String
    let detail: String
    let coordinate: CodableCoordinate?
    let distanceFromStartMeters: Double?

    enum TipType: String, Codable {
        case hill
        case speedZone
        case sharpTurn
        case evOpportunity
        case trafficSlowdown
        case longStraight
    }
}
