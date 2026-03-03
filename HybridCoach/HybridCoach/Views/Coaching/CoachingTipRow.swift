import SwiftUI

struct CoachingTipRow: View {
    let tip: CoachingTip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon)
                .font(.title3)
                .foregroundStyle(severityColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tip.category.rawValue)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(severityColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(severityColor.opacity(0.12), in: Capsule())

                    Spacer()

                    Text(tip.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(tip.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var severityIcon: String {
        switch tip.severity {
        case .info: "info.circle.fill"
        case .suggestion: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var severityColor: Color {
        switch tip.severity {
        case .info: .blue
        case .suggestion: .orange
        case .warning: .red
        }
    }
}
