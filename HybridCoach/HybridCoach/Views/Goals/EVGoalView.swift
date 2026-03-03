import SwiftUI
import Charts

/// EV Mode Goal dashboard with progress ring, streak counter, and weekly chart.
struct EVGoalView: View {
    @Environment(EVGoalStore.self) private var goalStore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let progress = goalStore.todayProgress(goalPercentage: settings.evGoalPercentage)
        let streakInfo = goalStore.streak()

        List {
            Section {
                progressRingCard(evPercent: progress.evPercent, goalMet: progress.goalMet)
            }

            Section("Streak") {
                HStack {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Current Streak")
                                .font(.subheadline)
                            Text("\(streakInfo.currentStreak) day\(streakInfo.currentStreak == 1 ? "" : "s")")
                                .font(.title3.bold())
                                .foregroundStyle(.orange)
                        }
                    } icon: {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                            .font(.title2)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("Longest")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(streakInfo.longestStreak)")
                            .font(.title3.bold())
                            .monospacedDigit()
                    }
                }
            }

            Section("This Week") {
                weeklyBarChart
            }

            Section {
                NavigationLink {
                    // Navigate to Settings for goal adjustment
                    SettingsView()
                } label: {
                    Label("Adjust EV Goal Target", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle("EV Goal")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Progress Ring

    private func progressRingCard(evPercent: Double, goalMet: Bool) -> some View {
        VStack(spacing: 16) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 12)
                    .frame(width: 160, height: 160)

                // Progress ring
                Circle()
                    .trim(from: 0, to: min(evPercent / 100.0, 1.0))
                    .stroke(
                        goalMet ? Color.green.gradient : Color.blue.gradient,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: evPercent)

                // Center text
                VStack(spacing: 4) {
                    Text(String(format: "%.0f%%", evPercent))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(goalMet ? .green : .primary)

                    Text("of \(Int(settings.evGoalPercentage))% goal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if goalMet {
                Label("Goal Met!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                Text("Keep driving in EV mode to reach your goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Weekly Bar Chart

    private var weeklyBarChart: some View {
        let recentDays = goalStore.recentWeek()

        return Chart(recentDays) { stat in
            BarMark(
                x: .value("Day", shortDayLabel(stat.dateKey)),
                y: .value("EV%", stat.evPercent)
            )
            .foregroundStyle(stat.metGoal ? Color.green.gradient : Color.blue.gradient)
            .cornerRadius(4)

            // Goal line
            RuleMark(y: .value("Goal", settings.evGoalPercentage))
                .foregroundStyle(.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartYAxisLabel("EV %")
        .chartYScale(domain: 0...100)
        .frame(height: 180)
    }

    private func shortDayLabel(_ dateKey: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateKey) else { return dateKey }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return out.string(from: date)
    }
}
