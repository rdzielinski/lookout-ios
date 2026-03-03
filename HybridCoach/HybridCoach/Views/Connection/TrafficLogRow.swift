import SwiftUI

struct TrafficLogRow: View {
    let entry: TrafficLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.direction.rawValue)
                .font(.caption2)
                .fontWeight(.bold)
                .monospaced()
                .foregroundStyle(directionColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.hexString)
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(3)

                Text(entry.asciiString)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    private var directionColor: Color {
        switch entry.direction {
        case .sent: return .blue
        case .received: return .green
        case .unsolicited: return .orange
        }
    }
}
