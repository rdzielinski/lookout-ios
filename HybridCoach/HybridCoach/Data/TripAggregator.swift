import Foundation

/// Static utility for aggregating trip data over time periods.
enum TripAggregator {

    // MARK: - Types

    struct WeeklyAverage: Identifiable {
        let id: String  // e.g. "2026-W09"
        let weekLabel: String
        let avgMPG: Double
        let evPercent: Double
        let avgScore: Int
        let tripCount: Int
    }

    struct MonthlyAverage: Identifiable {
        let id: String  // e.g. "2026-03"
        let monthLabel: String
        let avgMPG: Double
        let evPercent: Double
        let avgScore: Int
        let tripCount: Int
    }

    struct LifetimeSummary {
        let totalTrips: Int
        let totalMiles: Double
        let totalFuelGallons: Double
        let overallMPG: Double
        let overallEVPercent: Double
        let averageScore: Int
        let estimatedSavingsGallons: Double  // vs 30 MPG baseline
        let totalDrivingSeconds: Double
    }

    // MARK: - Weekly

    static func weeklyAverages(trips: [Trip]) -> [WeeklyAverage] {
        let calendar = Calendar.current

        var grouped: [String: [Trip]] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"

        for trip in trips {
            let year = formatter.string(from: trip.startTime)
            let week = calendar.component(.weekOfYear, from: trip.startTime)
            let key = "\(year)-W\(String(format: "%02d", week))"
            grouped[key, default: []].append(trip)
        }

        return grouped.sorted(by: { $0.key < $1.key }).map { key, trips in
            let totalMiles = trips.reduce(0.0) { $0 + $1.distanceMiles }
            let totalGallons = trips.reduce(0.0) { $0 + $1.fuelUsedGallons }
            let avgMPG = totalGallons > 0.001 ? totalMiles / totalGallons : 0
            let evTotal = trips.reduce(0.0) { $0 + $1.evModeSeconds }
            let driveTotal = trips.reduce(0.0) { $0 + $1.totalSeconds }
            let evPercent = driveTotal > 0 ? (evTotal / driveTotal) * 100.0 : 0
            let avgScore = trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.averageEfficiencyScore } / trips.count

            // Friendly label: "Mar 3"
            let label: String = {
                guard let firstTrip = trips.sorted(by: { $0.startTime < $1.startTime }).first else { return key }
                let f = DateFormatter()
                f.dateFormat = "MMM d"
                return f.string(from: firstTrip.startTime)
            }()

            return WeeklyAverage(
                id: key, weekLabel: label, avgMPG: avgMPG,
                evPercent: evPercent, avgScore: avgScore, tripCount: trips.count
            )
        }
    }

    // MARK: - Monthly

    static func monthlyAverages(trips: [Trip]) -> [MonthlyAverage] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"

        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "MMM yyyy"

        var grouped: [String: [Trip]] = [:]
        for trip in trips {
            let key = formatter.string(from: trip.startTime)
            grouped[key, default: []].append(trip)
        }

        return grouped.sorted(by: { $0.key < $1.key }).map { key, trips in
            let totalMiles = trips.reduce(0.0) { $0 + $1.distanceMiles }
            let totalGallons = trips.reduce(0.0) { $0 + $1.fuelUsedGallons }
            let avgMPG = totalGallons > 0.001 ? totalMiles / totalGallons : 0
            let evTotal = trips.reduce(0.0) { $0 + $1.evModeSeconds }
            let driveTotal = trips.reduce(0.0) { $0 + $1.totalSeconds }
            let evPercent = driveTotal > 0 ? (evTotal / driveTotal) * 100.0 : 0
            let avgScore = trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.averageEfficiencyScore } / trips.count

            let label: String = {
                guard let first = trips.sorted(by: { $0.startTime < $1.startTime }).first else { return key }
                return labelFormatter.string(from: first.startTime)
            }()

            return MonthlyAverage(
                id: key, monthLabel: label, avgMPG: avgMPG,
                evPercent: evPercent, avgScore: avgScore, tripCount: trips.count
            )
        }
    }

    // MARK: - Lifetime

    static func lifetimeStats(trips: [Trip]) -> LifetimeSummary {
        let totalMiles = trips.reduce(0.0) { $0 + $1.distanceMiles }
        let totalGallons = trips.reduce(0.0) { $0 + $1.fuelUsedGallons }
        let overallMPG = totalGallons > 0.001 ? totalMiles / totalGallons : 0
        let evTotal = trips.reduce(0.0) { $0 + $1.evModeSeconds }
        let driveTotal = trips.reduce(0.0) { $0 + $1.totalSeconds }
        let evPercent = driveTotal > 0 ? (evTotal / driveTotal) * 100.0 : 0
        let avgScore = trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.averageEfficiencyScore } / trips.count

        // Savings vs 30 MPG baseline
        let baselineGallons = totalMiles / 30.0
        let savings = max(0, baselineGallons - totalGallons)

        return LifetimeSummary(
            totalTrips: trips.count,
            totalMiles: totalMiles,
            totalFuelGallons: totalGallons,
            overallMPG: overallMPG,
            overallEVPercent: evPercent,
            averageScore: avgScore,
            estimatedSavingsGallons: savings,
            totalDrivingSeconds: driveTotal
        )
    }
}
