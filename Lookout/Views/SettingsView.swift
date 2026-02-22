import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss
    @ObservedObject var glassesService: GlassesService
    @StateObject private var speechService = SpeechService()
    @StateObject private var faceMemory = FaceMemoryService()
    @StateObject private var placeMemory = PlaceMemoryService()
    @StateObject private var userContext = UserContextStore()

    @State private var showResetConfirmation = false
    @State private var showMockGlasses = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark base
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // AI Provider
                        glassSection(
                            header: "AI Provider",
                            icon: "brain.head.profile",
                            iconColor: .blue
                        ) {
                            Picker("AI Provider", selection: $settings.selectedProvider) {
                                ForEach(AIProvider.allCases, id: \.self) { provider in
                                    Label(provider.rawValue, systemImage: provider.iconName).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .colorMultiply(.white)

                            settingsFooter("Choose which AI analyzes your camera feed.")
                        }

                        // API Keys
                        glassSection(
                            header: "API Keys",
                            icon: "key.fill",
                            iconColor: .yellow
                        ) {
                            apiKeyField(label: "Claude API Key", placeholder: "sk-ant-...", text: $settings.claudeAPIKey)
                            glassDivider()
                            apiKeyField(label: "OpenAI API Key", placeholder: "sk-...", text: $settings.openAIAPIKey)
                            glassDivider()
                            apiKeyField(label: "Google Places (Optional)", placeholder: "AIza...", text: $settings.googlePlacesAPIKey)
                            settingsFooter("Stored locally on device. Flight tracking uses OpenSky (free). Landmarks fall back to Wikipedia without Google key.")
                        }

                        // Meta Ray-Ban Glasses
                        glassSection(
                            header: "Meta Ray-Ban Glasses",
                            icon: "eyeglasses",
                            iconColor: .cyan
                        ) {
                            glassToggle("Glasses Mode", icon: "eyeglasses", isOn: $settings.glassesMode)

                            if settings.glassesMode {
                                glassDivider()

                                // Connection status card
                                VStack(spacing: 10) {
                                    // Status row
                                    HStack {
                                        Image(systemName: glassesConnectionIcon)
                                            .font(.footnote)
                                            .foregroundStyle(glassesConnectionColor)
                                            .frame(width: 20)
                                        Text(glassesConnectionLabel)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(glassesService.connectionState.rawValue)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(glassesConnectionColor)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(glassesConnectionColor.opacity(0.15), in: Capsule())
                                    }

                                    // Attempt info during retry
                                    if let attemptInfo = glassesService.connectionAttemptInfo,
                                       glassesService.connectionState == .connecting {
                                        HStack(spacing: 6) {
                                            ProgressView().tint(.orange).scaleEffect(0.7)
                                            Text(attemptInfo)
                                                .font(.caption).foregroundStyle(.orange.opacity(0.8))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 30)
                                    }

                                    // Error message
                                    if glassesService.connectionState == .error,
                                       let errorMsg = glassesService.lastError {
                                        Text(errorMsg)
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.9))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 30)
                                    }

                                    // Action buttons
                                    HStack(spacing: 10) {
                                        if glassesService.connectionState == .disconnected || glassesService.connectionState == .error {
                                            Button {
                                                glassesService.retryConnection()
                                            } label: {
                                                Label(
                                                    glassesService.connectionState == .error ? "Retry" : "Connect Glasses",
                                                    systemImage: glassesService.connectionState == .error ? "arrow.clockwise" : "link"
                                                )
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(.cyan, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }
                                        } else if glassesService.connectionState == .connecting {
                                            Button {
                                                glassesService.disconnect()
                                            } label: {
                                                Label("Cancel", systemImage: "xmark")
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.white)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 10)
                                                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }
                                        } else if glassesService.connectionState == .connected || glassesService.connectionState == .streaming {
                                            Button {
                                                glassesService.disconnect()
                                            } label: {
                                                Label("Disconnect", systemImage: "link.badge.plus")
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.red)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 10)
                                                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }
                                        }

                                        Button {
                                            GlassesService.openBluetoothSettings()
                                        } label: {
                                            Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                    }

                                    if let name = glassesService.deviceName {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2).foregroundStyle(.green)
                                            Text(name)
                                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 30)
                                    }
                                }

                                glassDivider()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Trigger Phrase")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.5))
                                    TextField("lookout", text: $settings.glassesTriggerPhrase)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                                glassDivider()
                                glassToggle("Auto-Listen on Connect", icon: "mic.fill", isOn: $settings.glassesAutoListen)
                            }

                            settingsFooter(
                                settings.glassesMode
                                ? "Say your trigger phrase to scan. Results spoken through glasses speakers."
                                : "Connect Meta Ray-Ban for hands-free scanning. Requires Meta AI app."
                            )
                        }

                        // Intelligence
                        glassSection(
                            header: "Intelligence",
                            icon: "sparkles",
                            iconColor: .purple
                        ) {
                            glassToggle("Smart Narration", icon: "waveform", isOn: $settings.smartNarrationEnabled)
                            glassDivider()
                            glassToggle("Face Recognition", icon: "person.crop.circle", isOn: $settings.faceRecognitionEnabled)
                            glassDivider()
                            glassToggle("Place Memory", icon: "mappin.circle.fill", isOn: $settings.placeMemoryEnabled)
                            settingsFooter("Smart Narration uses AI to generate natural speech. Face Recognition remembers named people. Place Memory saves familiar locations.")
                        }

                        // About You
                        glassSection(
                            header: "About You",
                            icon: "person.text.rectangle",
                            iconColor: .mint
                        ) {
                            ZStack(alignment: .topLeading) {
                                if settings.personalContext.isEmpty {
                                    Text("Tell Lookout about yourself — who you are, what you're into, what kind of responses you prefer...")
                                        .foregroundStyle(.white.opacity(0.3))
                                        .font(.subheadline)
                                        .padding(.top, 8).padding(.leading, 4)
                                }
                                TextEditor(text: $settings.personalContext)
                                    .frame(minHeight: 120)
                                    .scrollContentBackground(.hidden)
                                    .foregroundStyle(.white)
                                    .font(.subheadline)
                            }
                            settingsFooter("Included in every AI call so Lookout can personalize responses. Stored locally only.")
                        }

                        // Voice Output
                        glassSection(
                            header: "Voice Output",
                            icon: "speaker.wave.3.fill",
                            iconColor: .orange
                        ) {
                            glassToggle("Voice Output", icon: "speaker.wave.2", isOn: $settings.voiceOutputEnabled)

                            if settings.voiceOutputEnabled {
                                glassDivider()
                                Picker("Voice Engine", selection: $settings.voiceEngine) {
                                    ForEach(VoiceEngine.allCases, id: \.self) { engine in
                                        Text(engine.rawValue).tag(engine)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: settings.voiceEngine) { _, _ in syncSpeechSettings() }

                                if settings.voiceEngine == .elevenLabs {
                                    glassDivider()
                                    apiKeyField(label: "ElevenLabs API Key", placeholder: "xi-...", text: $settings.elevenLabsAPIKey)
                                        .onChange(of: settings.elevenLabsAPIKey) { _, _ in syncSpeechSettings() }
                                    glassDivider()
                                    Picker("Voice", selection: $settings.elevenLabsVoiceId) {
                                        ForEach(ElevenLabsVoice.presets) { voice in
                                            Text(voice.name).tag(voice.id)
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .onChange(of: settings.elevenLabsVoiceId) { _, newValue in
                                        if let voice = ElevenLabsVoice.presets.first(where: { $0.id == newValue }) {
                                            settings.elevenLabsVoiceName = voice.name
                                        }
                                        syncSpeechSettings()
                                    }
                                } else {
                                    glassDivider()
                                    Picker("Voice", selection: $speechService.selectedVoice) {
                                        ForEach(VoiceStyle.allCases, id: \.self) { voice in
                                            Text(voice.rawValue).tag(voice)
                                        }
                                    }
                                    .foregroundStyle(.white)
                                }

                                glassDivider()
                                Button("Test Voice") {
                                    syncSpeechSettings()
                                    speechService.speakSegments([
                                        "This is Lookout.",
                                        "That's a Red-tailed Hawk — pretty common in the Midwest but always impressive.",
                                        "You can see more on iNaturalist."
                                    ])
                                }
                                .foregroundStyle(.cyan)
                            }

                            settingsFooter(settings.voiceEngine == .elevenLabs
                                ? "ElevenLabs provides natural voices. 10,000 chars/month free."
                                : "Download Premium voices in Settings → Accessibility → Spoken Content for best quality."
                            )
                        }

                        // Active Skills
                        glassSection(
                            header: "Active Skills",
                            icon: "bolt.fill",
                            iconColor: .yellow
                        ) {
                            VStack(spacing: 0) {
                                glassSkillRow(name: "Flight Tracking", icon: "airplane", status: .available, note: "OpenSky Network (free)", color: SkillCategory.flight.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Landmark ID", icon: "building.2",
                                              status: settings.googlePlacesAPIKey.isEmpty ? .partial : .available,
                                              note: settings.googlePlacesAPIKey.isEmpty ? "Wikipedia only" : "Google Places + Wikipedia",
                                              color: SkillCategory.landmark.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Music ID", icon: "music.note", status: .available, note: "ShazamKit (built-in)", color: SkillCategory.music.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Plant & Animal ID", icon: "leaf", status: .available, note: "iNaturalist (free)", color: SkillCategory.plant.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Vehicle ID", icon: "car", status: .available, note: "NHTSA (free)", color: SkillCategory.vehicle.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Product / Barcode", icon: "barcode", status: .available, note: "Vision + Open Food Facts + UPCitemdb", color: SkillCategory.product.skillColor)
                                glassDivider()
                                glassSkillRow(name: "Face Recognition", icon: "person.crop.circle",
                                              status: settings.faceRecognitionEnabled ? .available : .unavailable,
                                              note: settings.faceRecognitionEnabled ? "On-device Vision" : "Disabled",
                                              color: .blue)
                            }
                        }

                        // Known Faces
                        if settings.faceRecognitionEnabled {
                            glassSection(
                                header: "Known Faces",
                                icon: "person.crop.circle.fill",
                                iconColor: .blue,
                                count: faceMemory.knownFaces.count
                            ) {
                                if faceMemory.knownFaces.isEmpty {
                                    Text("No saved faces yet")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.4))
                                        .padding(.vertical, 4)
                                } else {
                                    ForEach(faceMemory.knownFaces) { face in
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle().fill(Color.blue.opacity(0.2)).frame(width: 40, height: 40)
                                                Image(systemName: "person.crop.circle.fill")
                                                    .font(.title3).foregroundStyle(.blue)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(face.name).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                                                HStack(spacing: 6) {
                                                    if !face.relationship.isEmpty {
                                                        Text(face.relationship)
                                                    }
                                                    Text("·")
                                                    Text("Seen \(face.timesSeen)×")
                                                }
                                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                                            }
                                            Spacer()
                                            Text("\(face.sampleCount) samples")
                                                .font(.caption2).foregroundStyle(.white.opacity(0.35))
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                settingsFooter("🔒 Face data stored on-device via Apple Vision. Swipe to delete.")
                            }
                        }

                        // Saved Places
                        if settings.placeMemoryEnabled {
                            glassSection(
                                header: "Saved Places",
                                icon: "mappin.circle.fill",
                                iconColor: .red,
                                count: placeMemory.savedPlaces.count
                            ) {
                                if placeMemory.savedPlaces.isEmpty {
                                    Text("No saved places yet")
                                        .font(.subheadline).foregroundStyle(.white.opacity(0.4))
                                        .padding(.vertical, 4)
                                } else {
                                    ForEach(placeMemory.savedPlaces) { place in
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle().fill(Color.red.opacity(0.2)).frame(width: 36, height: 36)
                                                Image(systemName: place.category.iconName)
                                                    .font(.footnote).foregroundStyle(.red)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(place.name).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                                                HStack(spacing: 6) {
                                                    Text(place.category.rawValue)
                                                    Text("·")
                                                    Text("\(place.visitCount) visits")
                                                }
                                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                settingsFooter("Places matched by GPS within 100m.")
                            }
                        }

                        // Stats
                        glassSection(
                            header: "Your Stats",
                            icon: "chart.bar.fill",
                            iconColor: .green
                        ) {
                            statRow("Total Scans", value: "\(userContext.context.totalScans)")
                            if let top = userContext.context.categoryCounts.max(by: { $0.value < $1.value }) {
                                glassDivider()
                                statRow("Most Scanned", value: "\(top.key.capitalized) (\(top.value))")
                            }
                            glassDivider()
                            statRow("Known Faces", value: "\(faceMemory.knownFaces.count)")
                            glassDivider()
                            statRow("Saved Places", value: "\(placeMemory.savedPlaces.count)")
                            glassDivider()
                            statRow("Products Learned", value: "\(userContext.context.knownProducts.count)")
                            glassDivider()
                            statRow("Known Pets", value: "\(userContext.knownPets.count)")
                        }

                        // Developer
                        glassSection(
                            header: "Developer",
                            icon: "ladybug.fill",
                            iconColor: .orange
                        ) {
                            glassToggle("Scan Debug Trace", icon: "ladybug", isOn: $settings.developerTraceEnabled)
                            #if DEBUG
                            glassDivider()
                            Button {
                                showMockGlasses = true
                            } label: {
                                Label("Test Mock Glasses", systemImage: "eyeglasses")
                                    .foregroundStyle(.cyan)
                            }
                            #endif
                            settingsFooter("Shows debug panel after scans with model output, routing decisions, and context.")
                        }

                        // Privacy & Data
                        glassSection(
                            header: "Privacy & Data",
                            icon: "lock.shield.fill",
                            iconColor: .green
                        ) {
                            NavigationLink {
                                PrivacyDetailView()
                            } label: {
                                HStack {
                                    Image(systemName: "lock.shield").foregroundStyle(.green)
                                    Text("View Full Privacy Details").foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            glassDivider()
                            privacySummaryRow(icon: "iphone", color: .green,
                                title: "On-Device Storage",
                                detail: "Faces, pets, places, products, preferences, API keys")
                            glassDivider()
                            privacySummaryRow(icon: "arrow.up.circle", color: .orange,
                                title: "Sent When You Scan",
                                detail: "Photos → AI provider, Barcodes → public databases")
                            glassDivider()
                            privacySummaryRow(icon: "xmark.shield.fill", color: .red,
                                title: "No Servers, No Tracking, No Ads",
                                detail: "Lookout has no backend. All data stays with you.")
                        }

                        // Data Management
                        glassSection(
                            header: "Data Management",
                            icon: "trash.fill",
                            iconColor: .red
                        ) {
                            Button(role: .destructive) {
                                showResetConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash").foregroundStyle(.red)
                                    Text("Reset All Memory").foregroundStyle(.red)
                                    Spacer()
                                }
                            }
                            settingsFooter("Erases all faces, places, scan history, and learned preferences. Cannot be undone.")
                        }

                        // About
                        glassSection(
                            header: "About Lookout",
                            icon: "eye.fill",
                            iconColor: .cyan
                        ) {
                            statRow("Version", value: "2.0.0")
                            glassDivider()
                            statRow("Concept", value: "Contextual AI + Memory")
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .alert("Reset All Memory?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Everything", role: .destructive) {
                    faceMemory.removeAllFaces()
                    placeMemory.removeAllPlaces()
                    userContext.resetContext()
                }
            } message: {
                Text("This will erase all saved faces, places, pets, product memory, and scan history. This cannot be undone.")
            }
            #if DEBUG
            .sheet(isPresented: $showMockGlasses) { MockGlassesTestView() }
            #endif
        }
    }

    // MARK: - Glass Section Builder
    @ViewBuilder
    private func glassSection<Content: View>(
        header: String,
        icon: String,
        iconColor: Color,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let count = count {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }

            // Card body
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(glassSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
        }
    }

    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.16))
            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.clear],
                startPoint: .topLeading, endPoint: .center
            )
        }
    }

    // MARK: - Sub-components
    private func glassDivider() -> some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 8)
    }

    private func settingsFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func glassToggle(_ label: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(isOn.wrappedValue ? .white : .white.opacity(0.4))
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
        .tint(.cyan)
    }

    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
            SecureField(placeholder, text: text)
                .textContentType(.password)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.cyan)
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.white)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func privacySummaryRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.white)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func glassSkillRow(name: String, icon: String, status: SkillStatusRow.SkillStatus, note: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).foregroundStyle(.white)
                Text(note).font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Text(status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(status.color.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private func syncSpeechSettings() {
        speechService.voiceEngine = settings.voiceEngine
        speechService.elevenLabsAPIKey = settings.elevenLabsAPIKey
        speechService.elevenLabsVoiceId = settings.elevenLabsVoiceId
        speechService.selectedVoice = settings.selectedVoiceStyle
    }

    // MARK: - Glasses Connection Helpers

    private var glassesConnectionColor: Color {
        switch glassesService.connectionState {
        case .connected, .streaming: return .green
        case .connecting, .searching: return .orange
        case .error: return .red
        case .disconnected: return .white.opacity(0.4)
        }
    }

    private var glassesConnectionIcon: String {
        switch glassesService.connectionState {
        case .connected, .streaming: return "checkmark.circle.fill"
        case .connecting, .searching: return "antenna.radiowaves.left.and.right"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "link.badge.plus"
        }
    }

    private var glassesConnectionLabel: String {
        switch glassesService.connectionState {
        case .connected, .streaming: return "Glasses Connected"
        case .connecting: return "Looking for glasses..."
        case .searching: return "Registering..."
        case .error: return "Connection Failed"
        case .disconnected: return "Not Connected"
        }
    }
}

// MARK: - Skill Status Row (preserved for compatibility)
struct SkillStatusRow: View {
    let name: String
    let icon: String
    let status: SkillStatus
    let note: String

    enum SkillStatus {
        case available, partial, unavailable

        var color: Color {
            switch self {
            case .available: return .green
            case .partial: return .orange
            case .unavailable: return .red
            }
        }

        var label: String {
            switch self {
            case .available: return "Ready"
            case .partial: return "Partial"
            case .unavailable: return "Off"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(status.color.opacity(0.15))
                .foregroundStyle(status.color)
                .clipShape(Capsule())
        }
    }
}
