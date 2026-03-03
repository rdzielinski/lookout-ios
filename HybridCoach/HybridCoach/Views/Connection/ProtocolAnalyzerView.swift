import SwiftUI

struct ProtocolAnalyzerView: View {
    @Environment(ProtocolAnalyzerStore.self) var store
    @Environment(BluetoothManager.self) var bluetooth

    @State private var prober: ProtocolProber?

    var body: some View {
        List {
            deviceInfoSection
            gattTreeSection
            probeControlsSection
            probeResultsSection
            patternsSection
            trafficLogPreviewSection
        }
        .navigationTitle("Protocol Analyzer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let prober {
                    NavigationLink {
                        InteractiveConsoleView(prober: prober)
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: store.exportReport()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            prober = bluetooth.createProtocolProber()
        }
    }

    // MARK: - Device Info Section

    private var deviceInfoSection: some View {
        Section("Device Information") {
            if store.deviceInfo.isEmpty && store.deviceInfo.peripheralName == nil {
                Text("No device information available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let name = store.deviceInfo.peripheralName {
                    infoRow("Name", name)
                }
                if let uuid = store.deviceInfo.peripheralUUID {
                    infoRow("UUID", uuid.uuidString)
                }
                if let mfr = store.deviceInfo.manufacturerName {
                    infoRow("Manufacturer", mfr)
                }
                if let model = store.deviceInfo.modelNumber {
                    infoRow("Model", model)
                }
                if let serial = store.deviceInfo.serialNumber {
                    infoRow("Serial", serial)
                }
                if let fw = store.deviceInfo.firmwareRevision {
                    infoRow("Firmware", fw)
                }
                if let hw = store.deviceInfo.hardwareRevision {
                    infoRow("Hardware", hw)
                }
                if let sw = store.deviceInfo.softwareRevision {
                    infoRow("Software", sw)
                }
            }
        }
    }

    // MARK: - GATT Tree Section

    @ViewBuilder
    private var gattTreeSection: some View {
        let grouped = Dictionary(grouping: store.gattCharacteristics) { $0.serviceUUID }

        if !grouped.isEmpty {
            Section("GATT Services (\(grouped.count))") {
                ForEach(grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { serviceUUID in
                    if let chars = grouped[serviceUUID] {
                        DisclosureGroup {
                            ForEach(chars) { char in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(char.characteristicName ?? char.characteristicUUID.uuidString)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("[\(char.properties)]")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let readVal = char.readValue {
                                        let hex = readVal.map { String(format: "%02X", $0) }.joined(separator: " ")
                                        Text(hex)
                                            .font(.caption2)
                                            .monospaced()
                                            .foregroundStyle(.blue)
                                    }
                                    if let str = char.readValueString, !str.isEmpty {
                                        Text("\"\(str)\"")
                                            .font(.caption2)
                                            .monospaced()
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            let svcName = chars.first?.serviceName ?? serviceUUID.uuidString
                            Label {
                                VStack(alignment: .leading) {
                                    Text(svcName)
                                        .font(.subheadline)
                                    Text("\(chars.count) characteristic\(chars.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Probe Controls

    private var probeControlsSection: some View {
        Section("Protocol Probes") {
            if store.isProbing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView(value: store.probeProgress)
                        Text("\(Int(store.probeProgress * 100))%")
                            .font(.caption)
                            .monospaced()
                    }

                    Text(store.probeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Stop Probing", role: .destructive) {
                        prober?.stopProbing()
                    }
                }
            } else {
                Button {
                    guard let prober else { return }
                    Task {
                        await prober.runAllProbes()
                    }
                } label: {
                    Label("Run All Probes (\(ProtocolProber.probeCatalog.count))", systemImage: "play.fill")
                }
                .disabled(prober == nil)

                if !store.probeStatusMessage.isEmpty {
                    Text(store.probeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Probe Results

    @ViewBuilder
    private var probeResultsSection: some View {
        if !store.probeResults.isEmpty {
            Section("Results (\(store.probeResults.count))") {
                probeCategoryRows
            }
        }
    }

    @ViewBuilder
    private var probeCategoryRows: some View {
        let grouped = Dictionary(grouping: store.probeResults) { $0.category }
        ForEach(Array(ProbeResult.ProbeCategory.allCases), id: \.self) { (category: ProbeResult.ProbeCategory) in
            if let results = grouped[category] {
                probeCategoryDisclosure(category: category, results: results)
            }
        }
    }

    private func probeCategoryDisclosure(category: ProbeResult.ProbeCategory, results: [ProbeResult]) -> some View {
        let responded = results.filter { $0.status == .success || $0.status == .echo }.count
        return DisclosureGroup {
            ForEach(results) { result in
                probeResultRow(result)
            }
        } label: {
            HStack {
                Text(category.rawValue)
                    .font(.subheadline)
                Spacer()
                Text("\(responded)/\(results.count)")
                    .font(.caption)
                    .foregroundStyle(responded == 0 ? Color.secondary : Color.green)
            }
        }
    }

    private func probeResultRow(_ result: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                statusBadge(result.status)
                Text("\(result.durationMs)ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let sentHex = result.sentBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            Text("TX: \(sentHex)")
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.blue)

            if let recv = result.receivedBytes {
                let recvHex = recv.map { String(format: "%02X", $0) }.joined(separator: " ")
                Text("RX: \(recvHex)")
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.green)

                if let ascii = String(data: recv, encoding: .ascii)?
                    .trimmingCharacters(in: .controlCharacters),
                   !ascii.isEmpty {
                    Text("    \"\(ascii)\"")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ status: ProbeResult.ProbeStatus) -> some View {
        Text(status.rawValue)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.15))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: ProbeResult.ProbeStatus) -> Color {
        switch status {
        case .success: return .green
        case .timeout: return .secondary
        case .error: return .red
        case .echo: return .orange
        }
    }

    // MARK: - Patterns Section

    @ViewBuilder
    private var patternsSection: some View {
        if !store.detectedPatterns.isEmpty {
            Section("Detected Patterns") {
                ForEach(store.detectedPatterns, id: \.self) { pattern in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(pattern)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Traffic Log Preview

    @ViewBuilder
    private var trafficLogPreviewSection: some View {
        if !store.trafficLog.isEmpty {
            Section("Traffic Log (\(store.trafficLog.count) entries)") {
                // Show last 10 entries
                ForEach(store.trafficLog.suffix(10)) { entry in
                    TrafficLogRow(entry: entry)
                }

                if let prober {
                    NavigationLink {
                        InteractiveConsoleView(prober: prober)
                    } label: {
                        Label("Open Interactive Console", systemImage: "terminal")
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption)
                .monospaced()
        }
    }
}
