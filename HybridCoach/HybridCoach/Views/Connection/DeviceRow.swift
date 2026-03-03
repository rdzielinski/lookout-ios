import SwiftUI
import CoreBluetooth

struct DeviceRow: View {
    let peripheral: CBPeripheral
    let rssi: Int
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(signalColor)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peripheral.name ?? "Unknown Device")
                        .font(.headline)

                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(rssi) dBm")
                            .font(.caption)
                            .monospacedDigit()

                        Text(signalLabel)
                            .font(.caption2)
                            .foregroundStyle(signalColor)
                    }
                }
            }
        }
        .disabled(isConnecting)
    }

    private var signalColor: Color {
        switch rssi {
        case -50...0: .green
        case -70..<(-50): .blue
        case -85..<(-70): .orange
        default: .red
        }
    }

    private var signalLabel: String {
        switch rssi {
        case -50...0: "Strong"
        case -70..<(-50): "Good"
        case -85..<(-70): "Fair"
        default: "Weak"
        }
    }
}
