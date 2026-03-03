import SwiftUI

struct InteractiveConsoleView: View {
    let prober: ProtocolProber
    @Environment(ProtocolAnalyzerStore.self) var store

    @State private var inputText = ""
    @State private var inputMode: InputMode = .hex
    @State private var autoScroll = true

    enum InputMode: String, CaseIterable {
        case hex = "Hex"
        case ascii = "ASCII"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Traffic log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.trafficLog) { entry in
                            TrafficLogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: store.trafficLog.count) {
                    if autoScroll, let last = store.trafficLog.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Quick-send buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickButton("ATZ", data: Data("ATZ\r".utf8))
                    quickButton("ATI", data: Data("ATI\r".utf8))
                    quickButton("ATE0", data: Data("ATE0\r".utf8))
                    quickButton("0100", data: Data("0100\r".utf8))
                    quickButton("AA 00 01", data: Data([0xAA, 0x00, 0x01, 0x00, 0xAB]))
                    quickButton("55 55 AA", data: Data([0x55, 0x55, 0xAA, 0x01, 0x00]))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                Picker("Mode", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                TextField(inputMode == .hex ? "AA 55 01 00" : "ATZ", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .monospaced()
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { sendInput() }

                Button { sendInput() } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Auto-scroll", isOn: $autoScroll)

                    Button("Clear Log") {
                        store.clearTrafficLog()
                    }

                    ShareLink(item: store.exportReport()) {
                        Label("Export Report", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Actions

    private func sendInput() {
        guard !inputText.isEmpty else { return }

        let data: Data
        let label: String

        switch inputMode {
        case .hex:
            let hexStr = inputText
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "0x", with: "")
            guard hexStr.count % 2 == 0 else { return }
            var bytes: [UInt8] = []
            var idx = hexStr.startIndex
            while idx < hexStr.endIndex {
                let nextIdx = hexStr.index(idx, offsetBy: 2, limitedBy: hexStr.endIndex) ?? hexStr.endIndex
                if let byte = UInt8(String(hexStr[idx..<nextIdx]), radix: 16) {
                    bytes.append(byte)
                }
                idx = nextIdx
            }
            data = Data(bytes)
            label = "Manual (hex)"

        case .ascii:
            data = Data((inputText + "\r").utf8)
            label = "Manual (ASCII)"
        }

        let currentInput = inputText
        inputText = ""

        Task {
            _ = await prober.sendRawAndLog(data: data, label: "\(label): \(currentInput)")
        }
    }

    private func quickButton(_ title: String, data: Data) -> some View {
        Button(title) {
            Task {
                _ = await prober.sendRawAndLog(data: data, label: "Quick: \(title)")
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }
}
