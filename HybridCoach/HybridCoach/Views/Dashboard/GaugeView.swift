import SwiftUI

struct GaugeView: View {
    let value: Double
    let maxValue: Double
    let label: String
    let color: Color

    private var percentage: Double { min(max(value / maxValue, 0), 1.0) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background arc (270 degrees)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(135))

                // Value arc
                Circle()
                    .trim(from: 0, to: percentage * 0.75)
                    .stroke(
                        color.gradient,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .animation(.easeInOut(duration: 0.3), value: value)

                // Center text
                VStack(spacing: 2) {
                    Text(formatValue(value))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: value)

                    Text(label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
        }
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 1000 {
            return String(Int(v))
        } else if v >= 100 {
            return String(Int(v))
        } else {
            return String(format: "%.1f", v)
        }
    }
}

struct ReadoutTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    HStack {
        GaugeView(value: 1850, maxValue: 6000, label: "RPM", color: .green)
        GaugeView(value: 42, maxValue: 120, label: "MPH", color: .blue)
    }
    .padding()
}
