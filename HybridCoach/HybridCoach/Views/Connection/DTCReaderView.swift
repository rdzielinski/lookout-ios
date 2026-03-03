import SwiftUI

/// UI for reading and clearing diagnostic trouble codes via OBD-II.
struct DTCReaderView: View {
    @Environment(BluetoothManager.self) var bluetooth
    @State private var dtcService = DTCService()
    @State private var showClearConfirmation = false

    private var hasAdapter: Bool {
        bluetooth.connectionState == .ready
    }

    var body: some View {
        List {
            // Scan controls
            Section {
                Button {
                    Task {
                        if let adapter = bluetooth.connectedAdapter {
                            await dtcService.readAllDTCs(adapter: adapter)
                        }
                    }
                } label: {
                    HStack {
                        Label("Scan for Codes", systemImage: "magnifyingglass")
                        if dtcService.isReading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!hasAdapter || dtcService.isReading)

                if let scanDate = dtcService.lastScanDate {
                    HStack {
                        Text("Last scan")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(scanDate, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Error message
            if let error = dtcService.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            // Stored DTCs
            Section("Stored Codes") {
                if dtcService.storedCodes.isEmpty {
                    if dtcService.lastScanDate != nil {
                        ContentUnavailableView {
                            Label("No Stored Codes", systemImage: "checkmark.circle")
                        } description: {
                            Text("No confirmed trouble codes detected.")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Not Scanned", systemImage: "questionmark.circle")
                        } description: {
                            Text("Tap 'Scan for Codes' to check for trouble codes.")
                        }
                    }
                } else {
                    ForEach(dtcService.storedCodes) { dtc in
                        dtcRow(dtc)
                    }
                }
            }

            // Pending DTCs
            Section("Pending Codes") {
                if dtcService.pendingCodes.isEmpty {
                    if dtcService.lastScanDate != nil {
                        ContentUnavailableView {
                            Label("No Pending Codes", systemImage: "checkmark.circle")
                        } description: {
                            Text("No pending trouble codes detected.")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Not Scanned", systemImage: "questionmark.circle")
                        } description: {
                            Text("Pending codes are checked when you scan.")
                        }
                    }
                } else {
                    ForEach(dtcService.pendingCodes) { dtc in
                        dtcRow(dtc)
                    }
                }
            }

            // Clear codes
            if !dtcService.storedCodes.isEmpty || !dtcService.pendingCodes.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All Codes", systemImage: "trash")
                    }
                    .disabled(!hasAdapter || dtcService.isReading)
                } footer: {
                    Text("Clearing codes will turn off the check engine light and reset OBD-II readiness monitors. The light may return if the underlying issue is not fixed.")
                }
            }
        }
        .navigationTitle("DTC Reader")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Trouble Codes?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Codes", role: .destructive) {
                Task {
                    if let adapter = bluetooth.connectedAdapter {
                        await dtcService.clearDTCs(adapter: adapter)
                    }
                }
            }
        } message: {
            Text("This will clear all stored and pending trouble codes and turn off the check engine light. OBD-II readiness monitors will be reset. Are you sure?")
        }
    }

    // MARK: - DTC Row

    private func dtcRow(_ dtc: DiagnosticTroubleCode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // System badge
            Text(dtc.system.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(systemBadgeColor(dtc.system).opacity(0.2))
                .foregroundStyle(systemBadgeColor(dtc.system))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(dtc.code)
                        .font(.headline.monospaced())

                    if dtc.isPending {
                        Text("PENDING")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.2))
                            .foregroundStyle(.yellow)
                            .clipShape(Capsule())
                    }
                }

                Text(dtc.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(dtc.system.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func systemBadgeColor(_ system: DiagnosticTroubleCode.DTCSystem) -> Color {
        switch system {
        case .powertrain: .red
        case .body: .purple
        case .chassis: .orange
        case .network: .blue
        }
    }
}
