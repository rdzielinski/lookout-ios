import SwiftUI

struct MPGDisplayView: View {
    @Environment(DrivingDataStore.self) var data

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background circle
                Circle()
                    .fill(mpgBackgroundColor.opacity(0.12))
                    .frame(width: 150, height: 150)

                VStack(spacing: 2) {
                    if let mpg = data.instantMPG {
                        Text(String(format: "%.1f", mpg))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(mpgColor(mpg))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: mpg)

                        Text("MPG")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    } else if data.isEVMode {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)

                        Text("EV MODE")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("--")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text("MPG")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var mpgBackgroundColor: Color {
        if data.isEVMode { return .green }
        guard let mpg = data.instantMPG else { return .gray }
        return mpgColor(mpg)
    }

    private func mpgColor(_ mpg: Double) -> Color {
        switch mpg {
        case 50...: return .green
        case 35..<50: return .blue
        case 20..<35: return .orange
        default: return .red
        }
    }
}
