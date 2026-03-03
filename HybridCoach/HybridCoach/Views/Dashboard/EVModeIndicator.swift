import SwiftUI

struct EVModeIndicator: View {
    @Environment(DrivingDataStore.self) var data

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(data.isEVMode ? Color.green.opacity(0.15) : Color(.systemGray6))
                    .frame(width: 100, height: 100)

                VStack(spacing: 4) {
                    Image(systemName: data.isEVMode ? "bolt.fill" : "engine.combustion")
                        .font(.system(size: 28))
                        .foregroundStyle(data.isEVMode ? .green : .orange)
                        .contentTransition(.symbolEffect(.replace))

                    Text(data.isEVMode ? "EV" : "ICE")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(data.isEVMode ? .green : .primary)
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.5), value: data.isEVMode)
    }

    private var statusText: String {
        if data.isStationary {
            return data.isEngineRunning ? "Idling" : "Stopped"
        } else if data.isEVMode {
            return "Electric Drive"
        } else {
            return "Engine Running"
        }
    }
}
