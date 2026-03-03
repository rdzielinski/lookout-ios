import SwiftUI
import Charts

/// Trends dashboard showing lifetime aggregations and trend charts.
struct LifetimeStatsView: View {
    @Environment(TripRecorder.self) private var recorder

    private var trips: [Trip] { recorder.pastTrips }
    private var stats: TripAggregator.LifetimeSummary { TripAggregator.lifetimeStats(trips: trips) }
    private var weekly: [TripAggregator.WeeklyAverage] { TripAggregator.weeklyAverages(trips: trips) }
    private var monthly: [TripAggregator.MonthlyAverage] { TripAggregator.monthlyAverages(trips: trips) }

    var body: some View {
        List {
            if trips.count < 3 {
                ContentUnavailableView(
                    "Not Enough Data",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Complete at least 3 trips to see trends and statistics.")
                )
            } else {
                lifetimeSummarySection
                weeklyMPGSection
                monthlyEVSection
                scoreProgressionSection
            }
        }
        .navigationTitle("Lifetime Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Lifetime Summary Card

    private var lifetimeSummarySection: some View {
        Section("Lifetime Summary") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(title: "Total Trips", value: "\(stats.totalTrips)", icon: "car.fill", color: .blue)
                statCard(title: "Total Miles", value: String(format: "%.0f", stats.totalMiles), icon: "road.lanes", color: .green)
                statCard(title: "Overall MPG", value: String(format: "%.1f", stats.overallMPG), icon: "fuelpump.fill", color: .orange)
                statCard(title: "EV Mode", value: String(format: "%.0f%%", stats.overallEVPercent), icon: "bolt.fill", color: .green)
                statCard(title: "Avg Score", value: "\(stats.averageScore)", icon: "star.fill", color: .purple)
                statCard(title: "Fuel Saved", value: String(format: "%.1f gal", stats.estimatedSavingsGallons), icon: "leaf.fill", color: .green)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Weekly MPG Trend

    private var weeklyMPGSection: some View {
        Section("Weekly MPG Trend") {
            Chart(weekly) { week in
                LineMark(
                    x: .value("Week", week.weekLabel),
                    y: .value("MPG", week.avgMPG)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                .symbol(Circle().strokeBorder(lineWidth: 2))
            }
            .chartYAxisLabel("MPG")
            .frame(height: 200)
        }
    }

    // MARK: - Monthly EV%

    private var monthlyEVSection: some View {
        Section("Monthly EV Mode %") {
            Chart(monthly) { month in
                BarMark(
                    x: .value("Month", month.monthLabel),
                    y: .value("EV%", month.evPercent)
                )
                .foregroundStyle(.green.gradient)
                .cornerRadius(4)
            }
            .chartYAxisLabel("EV %")
            .frame(height: 200)
        }
    }

    // MARK: - Score Progression

    private var scoreProgressionSection: some View {
        Section("Efficiency Score Over Time") {
            Chart(weekly) { week in
                LineMark(
                    x: .value("Week", week.weekLabel),
                    y: .value("Score", week.avgScore)
                )
                .foregroundStyle(.purple)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Week", week.weekLabel),
                    y: .value("Score", week.avgScore)
                )
                .foregroundStyle(.purple.opacity(0.1))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("Score")
            .frame(height: 200)
        }
    }
}
