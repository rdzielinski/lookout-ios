import SwiftUI

/// Compact banner showing how the current trip compares to the historical average for a matched route.
struct RouteComparisonView: View {
    let currentMPG: Double
    let cluster: RouteCluster

    private var delta: Double {
        currentMPG - cluster.averageMPG
    }

    private var percentChange: Double {
        guard cluster.averageMPG > 0 else { return 0 }
        return (delta / cluster.averageMPG) * 100
    }

    private var isBetter: Bool { delta >= 0 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "road.lanes")
                .font(.title3)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text(String(format: "%.1f MPG", currentMPG))
                        .font(.subheadline.bold())
                        .monospacedDigit()

                    Text("vs avg")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(format: "%.1f", cluster.averageMPG))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Delta badge
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Image(systemName: isBetter ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(String(format: "%+.1f", delta))
                        .font(.subheadline.bold())
                        .monospacedDigit()
                }
                .foregroundStyle(isBetter ? .green : .orange)

                Text(String(format: "%+.0f%%", percentChange))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isBetter ? .green : .orange)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isBetter ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }
}
