import SwiftUI

struct ConnectionView: View {
    @Environment(BluetoothManager.self) var bluetooth
    @Environment(ProtocolAnalyzerStore.self) var analyzerStore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                connectionStatusSection

                if bluetooth.connectionState == .connected || bluetooth.connectionState == .ready {
                    connectedDeviceSection
                } else {
                    scanSection
                    discoveredDevicesSection
                }

                simulatorSection

                troubleshootingSection
            }
            .navigationTitle("Connect")
        }
    }

    // MARK: - Sections

    private var connectionStatusSection: some View {
        Section {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bluetooth.connectionState == .connecting {
                    ProgressView()
                }
            }
        }
    }

    private var connectedDeviceSection: some View {
        Section("Connected Device") {
            if let device = bluetooth.connectedPeripheral {
                VStack(alignment: .leading, spacing: 8) {
                    Label(device.name ?? "OBD Adapter", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text(device.identifier.uuidString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Disconnect", role: .destructive) {
                    bluetooth.disconnect()
                }
            }

            if let adapterInfo = bluetooth.adapterInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adapter Info")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(adapterInfo)
                        .font(.caption)
                        .monospaced()
                }
            }

            if !bluetooth.discoveredGATTInfo.isEmpty {
                DisclosureGroup("GATT Services") {
                    Text(bluetooth.discoveredGATTInfo)
                        .font(.caption2)
                        .monospaced()
                }
            }

            // DTC Reader link (available when adapter is ready)
            if bluetooth.connectionState == .ready {
                NavigationLink {
                    DTCReaderView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DTC Reader")
                                .font(.subheadline)
                            Text("Read & clear trouble codes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Show Protocol Analyzer link for AutoPhix or when analyzer is active
            if bluetooth.detectedAdapterType == .autoPhix || analyzerStore.isActive {
                NavigationLink {
                    ProtocolAnalyzerView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Protocol Analyzer")
                                .font(.subheadline)
                            Text("Reverse-engineer adapter protocol")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                if bluetooth.isScanning {
                    bluetooth.stopScan()
                } else {
                    bluetooth.startScan()
                }
            } label: {
                HStack {
                    Label(
                        bluetooth.isScanning ? "Stop Scanning" : "Scan for Adapters",
                        systemImage: bluetooth.isScanning ? "stop.circle" : "magnifyingglass"
                    )
                    if bluetooth.isScanning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
        }
    }

    private var discoveredDevicesSection: some View {
        Section("Discovered Devices") {
            if bluetooth.discoveredDevices.isEmpty {
                if bluetooth.isScanning {
                    ContentUnavailableView(
                        "Scanning...",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Looking for OBD-II adapters nearby. Make sure your adapter is powered on.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Devices Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Tap 'Scan for Adapters' to search for nearby OBD-II devices.")
                    )
                }
            } else {
                ForEach(bluetooth.discoveredDevices, id: \.peripheral.identifier) { device in
                    DeviceRow(
                        peripheral: device.peripheral,
                        rssi: device.rssi,
                        isConnecting: bluetooth.connectionState == .connecting,
                        onConnect: { bluetooth.connect(to: device.peripheral) }
                    )
                }
            }
        }
    }

    private var simulatorSection: some View {
        @Bindable var settings = settings

        return Section {
            Toggle("Test OBD-II Simulator", isOn: $settings.simulatorMode)

            if settings.simulatorMode {
                Label {
                    Text("Generating simulated engine data for indoor testing. Disable to return to live adapter mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Indoor Testing")
        } footer: {
            Text("Enable the simulator to use the app without a real OBD-II adapter or vehicle.")
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            DisclosureGroup("Connection Tips") {
                VStack(alignment: .leading, spacing: 8) {
                    tipRow(icon: "car", text: "Turn on your vehicle's ignition (engine can be off)")
                    tipRow(icon: "powerplug", text: "Ensure adapter is plugged into the OBD-II port (under the dashboard, driver side)")
                    tipRow(icon: "antenna.radiowaves.left.and.right", text: "Do NOT pair the adapter in iOS Settings — this app connects directly via BLE")
                    tipRow(icon: "arrow.counterclockwise", text: "Unplug and replug the adapter if it's unresponsive")
                    tipRow(icon: "location", text: "Stay within 10 feet of the adapter")
                }
                .padding(.vertical, 4)
            }

            if !bluetooth.errorMessage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(bluetooth.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func tipRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
    }

    private var statusIcon: String {
        switch bluetooth.connectionState {
        case .disconnected: "circle.slash"
        case .bluetoothOff: "bluetooth.slash"
        case .scanning: "magnifyingglass"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .ready: "checkmark.seal.fill"
        }
    }

    private var statusColor: Color {
        switch bluetooth.connectionState {
        case .disconnected: .secondary
        case .bluetoothOff: .red
        case .scanning: .blue
        case .connecting: .orange
        case .connected, .ready: .green
        }
    }

    private var statusTitle: String {
        switch bluetooth.connectionState {
        case .disconnected: "Disconnected"
        case .bluetoothOff: "Bluetooth Off"
        case .scanning: "Scanning"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .ready: "Ready"
        }
    }

    private var statusSubtitle: String {
        switch bluetooth.connectionState {
        case .disconnected: "Tap scan to find your OBD-II adapter"
        case .bluetoothOff: "Enable Bluetooth in Settings to continue"
        case .scanning: "Looking for OBD-II adapters..."
        case .connecting: "Establishing connection..."
        case .connected: "Initializing adapter..."
        case .ready: "Receiving live data"
        }
    }
}
