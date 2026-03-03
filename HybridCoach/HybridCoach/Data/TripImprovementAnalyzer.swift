import Foundation
import CoreLocation

/// Analyzes a completed trip's snapshots to identify segments of good and improvable driving.
struct TripImprovementAnalyzer {

    // MARK: - Models

    /// A contiguous segment of driving with a specific category.
    struct TripSegment: Identifiable {
        let id = UUID()
        let category: Category
        let coordinates: [CLLocationCoordinate2D]
        let message: String
        let severity: Severity

        enum Category: String {
            case highRPM = "High RPM"
            case missedEV = "Missed EV"
            case aggressiveAccel = "Aggressive Acceleration"
            case highSpeed = "High Speed"
            case goodEV = "EV Mode"
            case efficient = "Efficient Driving"
        }

        enum Severity {
            case good
            case info
            case warning
            case improvement
        }
    }

    /// Summary statistics for improvement segments.
    struct TripImprovementSummary {
        let totalSegments: Int
        let goodSegments: Int
        let improvementSegments: Int
        let efficientPercentage: Double
        let improvementPercentage: Double
    }

    // MARK: - Analysis

    /// Analyze a trip and optional route record to produce colored segments.
    static func analyze(trip: Trip, routeRecord: RouteRecord?) -> [TripSegment] {
        // Filter for snapshots with GPS data
        let gpsSnapshots = trip.snapshots.filter { $0.latitude != nil && $0.longitude != nil }
        guard gpsSnapshots.count >= 2 else { return [] }

        var segments: [TripSegment] = []

        // Run all detectors
        segments.append(contentsOf: detectHighRPM(snapshots: gpsSnapshots))
        segments.append(contentsOf: detectMissedEV(snapshots: gpsSnapshots))
        segments.append(contentsOf: detectAggressiveAcceleration(snapshots: gpsSnapshots))
        segments.append(contentsOf: detectHighSpeed(snapshots: gpsSnapshots))
        segments.append(contentsOf: detectGoodEV(snapshots: gpsSnapshots))
        segments.append(contentsOf: detectEfficient(snapshots: gpsSnapshots))

        return segments
    }

    /// Compute summary statistics from analyzed segments.
    static func summarize(segments: [TripSegment]) -> TripImprovementSummary {
        let good = segments.filter { $0.severity == .good }.count
        let improvement = segments.filter { $0.severity == .improvement || $0.severity == .warning }.count
        let total = segments.count

        let goodPct = total > 0 ? Double(good) / Double(total) * 100 : 0
        let improvePct = total > 0 ? Double(improvement) / Double(total) * 100 : 0

        return TripImprovementSummary(
            totalSegments: total,
            goodSegments: good,
            improvementSegments: improvement,
            efficientPercentage: goodPct,
            improvementPercentage: improvePct
        )
    }

    // MARK: - Detectors

    /// Detect segments where RPM exceeded 3000 (excessive engine strain).
    private static func detectHighRPM(snapshots: [TripSnapshot]) -> [TripSegment] {
        detectConsecutiveRuns(
            snapshots: snapshots,
            predicate: { $0.rpm > 3000 },
            category: .highRPM,
            message: "High RPM — keep below 3000 for better efficiency",
            severity: .improvement
        )
    }

    /// Detect segments where EV mode could have been used (low speed, engine running).
    private static func detectMissedEV(snapshots: [TripSnapshot]) -> [TripSegment] {
        detectConsecutiveRuns(
            snapshots: snapshots,
            predicate: { $0.speedMph < 30 && $0.rpm > 50 && $0.rpm < 1500 && !$0.isEVMode },
            category: .missedEV,
            message: "Missed EV opportunity — lighter throttle at low speeds",
            severity: .warning
        )
    }

    /// Detect aggressive acceleration (15+ mph jump between consecutive 5s snapshots).
    private static func detectAggressiveAcceleration(snapshots: [TripSnapshot]) -> [TripSegment] {
        var segments: [TripSegment] = []

        var runStart: Int? = nil
        for i in 1..<snapshots.count {
            let speedDelta = snapshots[i].speedMph - snapshots[i - 1].speedMph
            if speedDelta >= 15 {
                if runStart == nil { runStart = i - 1 }
            } else {
                if let start = runStart {
                    let coords = coordinatesFromRange(snapshots: snapshots, start: start, end: i)
                    if coords.count >= 2 {
                        segments.append(TripSegment(
                            category: .aggressiveAccel,
                            coordinates: coords,
                            message: "Aggressive acceleration — gradual throttle saves fuel",
                            severity: .improvement
                        ))
                    }
                    runStart = nil
                }
            }
        }
        // Close trailing run
        if let start = runStart {
            let coords = coordinatesFromRange(snapshots: snapshots, start: start, end: snapshots.count)
            if coords.count >= 2 {
                segments.append(TripSegment(
                    category: .aggressiveAccel,
                    coordinates: coords,
                    message: "Aggressive acceleration — gradual throttle saves fuel",
                    severity: .improvement
                ))
            }
        }

        return segments
    }

    /// Detect segments at highway speed (>55 mph) where aero drag increases fuel use.
    private static func detectHighSpeed(snapshots: [TripSnapshot]) -> [TripSegment] {
        detectConsecutiveRuns(
            snapshots: snapshots,
            predicate: { $0.speedMph > 55 },
            category: .highSpeed,
            message: "High speed — aerodynamic drag increases above 55 mph",
            severity: .warning
        )
    }

    /// Detect good EV mode segments.
    private static func detectGoodEV(snapshots: [TripSnapshot]) -> [TripSegment] {
        detectConsecutiveRuns(
            snapshots: snapshots,
            predicate: { $0.isEVMode },
            category: .goodEV,
            message: "Great EV driving — zero fuel used",
            severity: .good
        )
    }

    /// Detect efficient driving (high efficiency score, not EV).
    private static func detectEfficient(snapshots: [TripSnapshot]) -> [TripSegment] {
        detectConsecutiveRuns(
            snapshots: snapshots,
            predicate: { ($0.efficiencyScore ?? 0) >= 90 && !$0.isEVMode },
            category: .efficient,
            message: "Efficient hybrid driving — well done!",
            severity: .good
        )
    }

    // MARK: - Helpers

    /// Generic helper to find consecutive runs of matching snapshots and build TripSegments.
    private static func detectConsecutiveRuns(
        snapshots: [TripSnapshot],
        predicate: (TripSnapshot) -> Bool,
        category: TripSegment.Category,
        message: String,
        severity: TripSegment.Severity
    ) -> [TripSegment] {
        var segments: [TripSegment] = []
        var runStart: Int? = nil

        for i in 0..<snapshots.count {
            if predicate(snapshots[i]) {
                if runStart == nil { runStart = i }
            } else {
                if let start = runStart {
                    let coords = coordinatesFromRange(snapshots: snapshots, start: start, end: i)
                    if coords.count >= 2 {
                        segments.append(TripSegment(
                            category: category,
                            coordinates: coords,
                            message: message,
                            severity: severity
                        ))
                    }
                    runStart = nil
                }
            }
        }

        // Close trailing run
        if let start = runStart {
            let coords = coordinatesFromRange(snapshots: snapshots, start: start, end: snapshots.count)
            if coords.count >= 2 {
                segments.append(TripSegment(
                    category: category,
                    coordinates: coords,
                    message: message,
                    severity: severity
                ))
            }
        }

        return segments
    }

    /// Extract CLLocationCoordinate2D from a range of GPS-tagged snapshots.
    private static func coordinatesFromRange(
        snapshots: [TripSnapshot], start: Int, end: Int
    ) -> [CLLocationCoordinate2D] {
        (start..<end).compactMap { i in
            guard let lat = snapshots[i].latitude, let lon = snapshots[i].longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
