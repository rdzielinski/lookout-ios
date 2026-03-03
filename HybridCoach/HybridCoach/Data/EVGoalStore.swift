import Foundation

/// Tracks daily EV-mode driving sessions against a user-set goal percentage.
@Observable
final class EVGoalStore {

    // MARK: - Types

    struct DailyEVStat: Codable, Identifiable {
        var id: String { dateKey }
        let dateKey: String  // "yyyy-MM-dd"
        var evModeSeconds: Double
        var totalDrivingSeconds: Double
        var metGoal: Bool

        var evPercent: Double {
            totalDrivingSeconds > 0 ? (evModeSeconds / totalDrivingSeconds) * 100.0 : 0
        }
    }

    struct GoalStreak {
        var currentStreak: Int
        var longestStreak: Int
        var lastMetDate: String?
    }

    // MARK: - Properties

    private(set) var dailyStats: [DailyEVStat] = []

    private let storageURL: URL

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("ev_goals.json")
        load()
    }

    // MARK: - Recording

    /// Record a driving session's EV data for the current day.
    func recordDrivingSession(evSeconds: Double, totalSeconds: Double, date: Date = Date(), goalPercentage: Double) {
        let key = Self.dateKey(for: date)

        if let idx = dailyStats.firstIndex(where: { $0.dateKey == key }) {
            dailyStats[idx].evModeSeconds += evSeconds
            dailyStats[idx].totalDrivingSeconds += totalSeconds
            let evPct = dailyStats[idx].evPercent
            dailyStats[idx].metGoal = evPct >= goalPercentage
        } else {
            let evPct = totalSeconds > 0 ? (evSeconds / totalSeconds) * 100.0 : 0
            let stat = DailyEVStat(
                dateKey: key,
                evModeSeconds: evSeconds,
                totalDrivingSeconds: totalSeconds,
                metGoal: evPct >= goalPercentage
            )
            dailyStats.append(stat)
        }

        save()
    }

    // MARK: - Queries

    func todayProgress(goalPercentage: Double) -> (evPercent: Double, goalMet: Bool) {
        let key = Self.dateKey(for: Date())
        guard let stat = dailyStats.first(where: { $0.dateKey == key }) else {
            return (0, false)
        }
        return (stat.evPercent, stat.evPercent >= goalPercentage)
    }

    func streak() -> GoalStreak {
        let sorted = dailyStats.sorted(by: { $0.dateKey > $1.dateKey })

        var current = 0
        var longest = 0
        var lastMet: String?

        // Current streak: consecutive days met goal ending today or yesterday
        for stat in sorted {
            if stat.metGoal {
                current += 1
                if lastMet == nil { lastMet = stat.dateKey }
            } else {
                break
            }
        }

        // Longest streak
        var run = 0
        for stat in dailyStats.sorted(by: { $0.dateKey < $1.dateKey }) {
            if stat.metGoal {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }

        return GoalStreak(currentStreak: current, longestStreak: longest, lastMetDate: lastMet)
    }

    /// Last 7 daily stats for the weekly chart.
    func recentWeek() -> [DailyEVStat] {
        let sorted = dailyStats.sorted(by: { $0.dateKey < $1.dateKey })
        return Array(sorted.suffix(7))
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(dailyStats)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("EVGoalStore: Failed to save — \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: storageURL)
            dailyStats = try JSONDecoder().decode([DailyEVStat].self, from: data)
        } catch {
            dailyStats = []
        }
    }

    // MARK: - Helpers

    private static func dateKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
