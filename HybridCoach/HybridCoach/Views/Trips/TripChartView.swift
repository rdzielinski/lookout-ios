import SwiftUI
import Charts

/// Charts sub-view showing trip snapshot data visualizations.
struct TripChartView: View {
    let trip: Trip

    private var snapshots: [TripSnapshot] { trip.snapshots }

    /// Seconds elapsed since trip start for a given snapshot.
    private func elapsed(_ snapshot: TripSnapshot) -> Double {
        snapshot.timestamp.timeIntervalSince(trip.startTime)
    }

    var body: some View {
        VStack(spacing: 24) {
            mpgOverTimeChart
            speedAndEVChart
            rpmDistributionChart
            if snapshots.contains(where: { $0.efficiencyScore != nil }) {
                efficiencyScoreChart
            }
        }
    }

    // MARK: - MPG Over Time

    private var mpgOverTimeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fuel Economy", systemImage: "fuelpump")
                .font(.headline)

            Chart {
                ForEach(snapshots.indices, id: \.self) { i in
                    let snap = snapshots[i]
                    if let mpg = snap.instantMPG {
                        LineMark(
                            x: .value("Time", elapsed(snap) / 60.0),
                            y: .value("MPG", min(mpg, 99.9))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }
                }

                // Average MPG reference line
                if trip.averageMPG > 0 {
                    RuleMark(y: .value("Average", trip.averageMPG))
                        .foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(format: "Avg %.1f", trip.averageMPG))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                }
            }
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("MPG")
            .chartYScale(domain: 0...100)
            .frame(height: 200)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Speed + EV Mode Regions

    private var speedAndEVChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speed & EV Mode", systemImage: "bolt.car")
                .font(.headline)

            Chart {
                // EV mode regions (green background)
                ForEach(snapshots.indices, id: \.self) { i in
                    let snap = snapshots[i]
                    if snap.isEVMode {
                        AreaMark(
                            x: .value("Time", elapsed(snap) / 60.0),
                            yStart: .value("Bottom", 0),
                            yEnd: .value("Top", snap.speedMph)
                        )
                        .foregroundStyle(.green.opacity(0.2))
                    }
                }

                // Speed line
                ForEach(snapshots.indices, id: \.self) { i in
                    let snap = snapshots[i]
                    LineMark(
                        x: .value("Time", elapsed(snap) / 60.0),
                        y: .value("Speed", snap.speedMph)
                    )
                    .foregroundStyle(.primary)
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("MPH")
            .frame(height: 200)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(.primary).frame(width: 8, height: 8)
                    Text("Speed").font(.caption2)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(.green.opacity(0.3)).frame(width: 12, height: 8)
                    Text("EV Mode").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - RPM Distribution

    private struct RPMBucket: Identifiable {
        let id: String
        let label: String
        let count: Int
    }

    private var rpmBuckets: [RPMBucket] {
        var counts = [0, 0, 0, 0, 0]
        for snap in snapshots {
            switch snap.rpm {
            case ..<1000:     counts[0] += 1
            case 1000..<2000: counts[1] += 1
            case 2000..<3000: counts[2] += 1
            case 3000..<4000: counts[3] += 1
            default:          counts[4] += 1
            }
        }
        let labels = ["0-1k", "1-2k", "2-3k", "3-4k", "4k+"]
        return labels.enumerated().map { RPMBucket(id: labels[$0.offset], label: labels[$0.offset], count: counts[$0.offset]) }
    }

    private var rpmDistributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("RPM Distribution", systemImage: "gauge.with.dots.needle.33percent")
                .font(.headline)

            Chart(rpmBuckets) { bucket in
                BarMark(
                    x: .value("RPM Range", bucket.label),
                    y: .value("Samples", bucket.count)
                )
                .foregroundStyle(rpmColor(for: bucket.label))
                .cornerRadius(4)
            }
            .chartYAxisLabel("Samples")
            .frame(height: 180)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func rpmColor(for label: String) -> Color {
        switch label {
        case "0-1k":  .green
        case "1-2k":  .blue
        case "2-3k":  .yellow
        case "3-4k":  .orange
        default:       .red
        }
    }

    // MARK: - Efficiency Score Timeline

    private var efficiencyScoreChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Efficiency Score", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)

            Chart {
                ForEach(snapshots.indices, id: \.self) { i in
                    let snap = snapshots[i]
                    if let score = snap.efficiencyScore {
                        LineMark(
                            x: .value("Time", elapsed(snap) / 60.0),
                            y: .value("Score", score)
                        )
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("Score")
            .chartYScale(domain: 0...100)
            .frame(height: 180)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
