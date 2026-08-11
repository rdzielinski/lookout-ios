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
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        AssistantSettingsSections(settings: settings)
                        providerAndKeysSection
                        glassesSettingsSection
                        intelligenceAndSpeedSection
                        personalAndVoiceSection
                        skillsAndMemorySection
                        systemAndAboutSection
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

    // MARK: - Provider & Keys

    @ViewBuilder
    private var providerAndKeysSection: some View {
        glassSection(header: "AI Provider", icon: "brain.head.profile", iconColor: .blue) {
            Picker("AI Provider", selection: $settings.selectedProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Label(provider.rawValue, systemImage: provider.iconName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .colorMultiply(.white)
            settingsFooter("Choose which AI analyzes your camera feed.")
        }

        glassSection(header: "API Keys", icon: "key.fill", iconColor: .yellow) {
            apiKeyField(label: "Claude API Key", placeholder: "sk-ant-...", text: $settings.claudeAPIKey)
            glassDivider()
            apiKeyField(label: "OpenAI API Key", placeholder: "sk-...", text: $settings.openAIAPIKey)
            glassDivider()
            apiKeyField(label: "Google Places (Optional)", placeholder: "AIza...", text: $settings.googlePlacesAPIKey)
            glassDivider()
            apiKeyField(label: "FlightRadar24 (Optional)", placeholder: "fr24_...", text: $settings.flightradar24APIKey)
            settingsFooter("Stored locally on device. FlightRadar24 provides rich flight data (airline, route, aircraft type). Falls back to OpenSky (free) without FR24 key.")
        }
    }

    // MARK: - Glasses Settings

    @ViewBuilder
    private var glassesSettingsSection: some View {
        glassSection(header: "Meta Ray-Ban Glasses", icon: "eyeglasses", iconColor: .cyan) {
            glassToggle("Glasses Mode", icon: "eyeglasses", isOn: $settings.glassesMode)

            if settings.glassesMode {
                glassDivider()
                GlassesConnectionCardView(glassesService: glassesService)
                glassDivider()
                glassesToggleList
            }

            settingsFooter(
                settings.glassesMode
                ? "Say your trigger phrase or press the camera button on your glasses to scan. Results spoken through glasses speakers. Audio-Only skips the screen UI. Hands-Free auto-listens for follow-up questions."
                : "Connect Meta Ray-Ban for hands-free scanning. Requires Meta AI app."
            )
        }
    }

    @ViewBuilder
    private var glassesToggleList: some View {
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
        glassDivider()
        glassToggle("Camera Button Trigger", icon: "camera.circle.fill", isOn: $settings.glassesCameraButtonEnabled)
        glassDivider()
        glassToggle("Audio-Only Mode", icon: "speaker.wave.2.fill", isOn: $settings.audioOnlyGlasses)
        glassDivider()
        glassToggle("Hands-Free Follow-Up", icon: "bubble.left.and.bubble.right.fill", isOn: $settings.handsFreeChatEnabled)
    }

    // MARK: - Intelligence & Speed

    @ViewBuilder
    private var intelligenceAndSpeedSection: some View {
        glassSection(header: "Intelligence", icon: "sparkles", iconColor: .purple) {
            glassToggle("Smart Narration", icon: "waveform", isOn: $settings.smartNarrationEnabled)
            glassDivider()
            glassToggle("Face Recognition", icon: "person.crop.circle", isOn: $settings.faceRecognitionEnabled)
            glassDivider()
            glassToggle("Place Memory", icon: "mappin.circle.fill", isOn: $settings.placeMemoryEnabled)
            settingsFooter("Smart Narration uses AI to generate natural speech. Face Recognition remembers named people. Place Memory saves familiar locations.")
        }

        speedAndAmbientSection
    }

    @ViewBuilder
    private var speedAndAmbientSection: some View {
        glassSection(header: "Speed & Ambient", icon: "bolt.fill", iconColor: .yellow) {
            glassToggle("Fast Model (Haiku)", icon: "hare", isOn: $settings.useFastModel)
            settingsFooter("Uses Claude Haiku for faster image classification (~1-2s faster). Slightly less accurate for ambiguous images.")
            glassDivider()
            glassToggle("Continuous Scan", icon: "arrow.triangle.2.circlepath", isOn: $settings.continuousScanEnabled)
            if settings.continuousScanEnabled {
                HStack {
                    Text("Interval")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(settings.continuousScanInterval))s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                Slider(value: $settings.continuousScanInterval, in: 5...30, step: 1)
                    .tint(.yellow)
            }
            settingsFooter("Periodically scans the camera and narrates what's around you.")
            glassDivider()
            glassToggle("Proactive Place Narration", icon: "location.fill", isOn: $settings.proactiveNarrationEnabled)
            settingsFooter("Speaks context when you arrive at a saved place.")
            glassDivider()
            glassToggle("Replay Buffer", icon: "backward.frame", isOn: $settings.replayBufferEnabled)
            settingsFooter("Keeps last 30 seconds of frames so you can ask 'What did I just see?'")
            glassDivider()
            glassToggle("Camera Auto-Sleep", icon: "moon.fill", isOn: $settings.cameraAutoSleepEnabled)
            if settings.cameraAutoSleepEnabled {
                HStack {
                    Text("Timeout")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(settings.cameraAutoSleepDelay))s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                Slider(value: $settings.cameraAutoSleepDelay, in: 30...300, step: 15)
                    .tint(.indigo)
            }
            settingsFooter("Automatically turns off the camera after inactivity to save battery. Say \"camera on\" or tap the bolt icon to wake.")
        }
    }

    // MARK: - Personal & Voice

    @ViewBuilder
    private var personalAndVoiceSection: some View {
        glassSection(header: "About You", icon: "person.text.rectangle", iconColor: .mint) {
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

        voiceOutputSection
    }

    @ViewBuilder
    private var voiceOutputSection: some View {
        glassSection(header: "Voice Output", icon: "speaker.wave.3.fill", iconColor: .orange) {
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
    }

    // MARK: - Skills & Memory

    @ViewBuilder
    private var skillsAndMemorySection: some View {
        activeSkillsSection

        if settings.faceRecognitionEnabled {
            knownFacesSection
        }

        if settings.placeMemoryEnabled {
            savedPlacesSection
        }
    }

    // MARK: - Active Skills

    // No @ViewBuilder needed — the body is a single expression now.
    private var activeSkillsSection: some View {
        glassSection(header: "Active Skills", icon: "bolt.fill", iconColor: .yellow) {
            ActiveSkillsList(skills: skillCatalog)
        }
    }

    /// The skill list as data.
    ///
    /// This used to be 29 views written out longhand inside one VStack — 15
    /// rows interleaved with 14 dividers. Swift 5.9 gave ViewBuilder a variadic
    /// buildBlock, so that compiles happily and then produces a TupleView of 29
    /// distinct nested types. The mangled name for that type is enormous, and
    /// swift_getTypeByMangledName recurses in proportion to it — which
    /// overflowed the stack at runtime once main's eight new skills landed.
    ///
    /// As data fed through a ForEach it is a single type no matter how many
    /// skills exist, so adding the next one can't reintroduce the crash.
    private var skillCatalog: [SkillRowSpec] {
        [
            SkillRowSpec(name: "Flight Tracking", icon: "airplane", status: .available,
                         note: "OpenSky Network (free)", color: SkillCategory.flight.skillColor),
            SkillRowSpec(name: "Landmark ID", icon: "building.2",
                         status: settings.googlePlacesAPIKey.isEmpty ? .partial : .available,
                         note: settings.googlePlacesAPIKey.isEmpty ? "Wikipedia only" : "Google Places + Wikipedia",
                         color: SkillCategory.landmark.skillColor),
            SkillRowSpec(name: "Music ID", icon: "music.note", status: .available,
                         note: "ShazamKit (built-in)", color: SkillCategory.music.skillColor),
            SkillRowSpec(name: "Plant & Animal ID", icon: "leaf", status: .available,
                         note: "iNaturalist (free)", color: SkillCategory.plant.skillColor),
            SkillRowSpec(name: "Vehicle ID", icon: "car", status: .available,
                         note: "NHTSA (free)", color: SkillCategory.vehicle.skillColor),
            SkillRowSpec(name: "Product / Barcode", icon: "barcode", status: .available,
                         note: "Vision + Open Food Facts + UPCitemdb", color: SkillCategory.product.skillColor),
            SkillRowSpec(name: "Translation", icon: "character.book.closed", status: .available,
                         note: "AI-powered text translation", color: SkillCategory.translation.skillColor),
            SkillRowSpec(name: "Food & Nutrition", icon: "fork.knife", status: .available,
                         note: "AI calorie/macro estimation", color: SkillCategory.food.skillColor),
            SkillRowSpec(name: "Drink ID", icon: "wineglass", status: .available,
                         note: "Wine, beer, coffee labels", color: SkillCategory.drink.skillColor),
            SkillRowSpec(name: "Receipt Scanner", icon: "receipt", status: .available,
                         note: "Expense tracking + OCR", color: SkillCategory.receipt.skillColor),
            SkillRowSpec(name: "Medication", icon: "pill", status: .available,
                         note: "OpenFDA (free)", color: SkillCategory.medication.skillColor),
            SkillRowSpec(name: "Book & Movie", icon: "book", status: .available,
                         note: "Open Library (free)", color: SkillCategory.book.skillColor),
            SkillRowSpec(name: "Business Card", icon: "person.text.rectangle", status: .available,
                         note: "AI contact extraction", color: SkillCategory.businessCard.skillColor),
            SkillRowSpec(name: "QR Code", icon: "qrcode", status: .available,
                         note: "URLs, WiFi, contacts", color: SkillCategory.qrCode.skillColor),
            SkillRowSpec(name: "Face Recognition", icon: "person.crop.circle",
                         status: settings.faceRecognitionEnabled ? .available : .unavailable,
                         note: settings.faceRecognitionEnabled ? "On-device Vision" : "Disabled",
                         color: .blue),
        ]
    }

    @ViewBuilder
    private var knownFacesSection: some View {
        glassSection(header: "Known Faces", icon: "person.crop.circle.fill", iconColor: .blue, count: faceMemory.knownFaces.count) {
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
                                Text("\u{00B7}")
                                Text("Seen \(face.timesSeen)\u{00D7}")
                            }
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                            if !face.notes.isEmpty {
                                Text(face.notes)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text("\(face.sampleCount) samples")
                            .font(.caption2).foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.vertical, 4)
                }
            }
            settingsFooter("Face data stored on-device via Apple Vision. Swipe to delete.")
        }
    }

    @ViewBuilder
    private var savedPlacesSection: some View {
        glassSection(header: "Saved Places", icon: "mappin.circle.fill", iconColor: .red, count: placeMemory.savedPlaces.count) {
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
                                Text("\u{00B7}")
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

    // MARK: - System & About

    @ViewBuilder
    private var systemAndAboutSection: some View {
        glassSection(header: "Your Stats", icon: "chart.bar.fill", iconColor: .green) {
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

        developerAndPrivacySection
    }

    @ViewBuilder
    private var developerAndPrivacySection: some View {
        glassSection(header: "Developer", icon: "ladybug.fill", iconColor: .orange) {
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

        glassSection(header: "Privacy & Data", icon: "lock.shield.fill", iconColor: .green) {
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

        glassSection(header: "Data Management", icon: "trash.fill", iconColor: .red) {
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

        glassSection(header: "About Lookout", icon: "eye.fill", iconColor: .cyan) {
            statRow("Version", value: "2.0.0")
            glassDivider()
            statRow("Concept", value: "Contextual AI + Memory")
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


    private func syncSpeechSettings() {
        speechService.voiceEngine = settings.voiceEngine
        speechService.elevenLabsAPIKey = settings.elevenLabsAPIKey
        speechService.elevenLabsVoiceId = settings.elevenLabsVoiceId
        speechService.selectedVoice = settings.selectedVoiceStyle
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

// MARK: - Glasses Connection Card (separate struct to avoid type-explosion crash)

struct GlassesConnectionCardView: View {
    @ObservedObject var glassesService: GlassesService

    var body: some View {
        VStack(spacing: 10) {
            connectionStatusRow
            attemptInfoRow
            errorRow
            actionButtons
            deviceNameRow
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var connectionStatusRow: some View {
        HStack {
            Image(systemName: connectionIcon)
                .font(.footnote)
                .foregroundStyle(connectionColor)
                .frame(width: 20)
            Text(connectionLabel)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(glassesService.connectionState.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(connectionColor)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(connectionColor.opacity(0.15), in: Capsule())
        }
    }

    @ViewBuilder
    private var attemptInfoRow: some View {
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
    }

    @ViewBuilder
    private var errorRow: some View {
        if glassesService.connectionState == .error,
           let errorMsg = glassesService.lastError {
            Text(errorMsg)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 30)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
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
    }

    @ViewBuilder
    private var deviceNameRow: some View {
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

    // MARK: - Connection Helpers

    private var connectionColor: Color {
        switch glassesService.connectionState {
        case .connected, .streaming: return .green
        case .connecting, .searching: return .orange
        case .error: return .red
        case .disconnected: return .white.opacity(0.4)
        }
    }

    private var connectionIcon: String {
        switch glassesService.connectionState {
        case .connected, .streaming: return "checkmark.circle.fill"
        case .connecting, .searching: return "antenna.radiowaves.left.and.right"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "link.badge.plus"
        }
    }

    private var connectionLabel: String {
        switch glassesService.connectionState {
        case .connected, .streaming: return "Glasses Connected"
        case .connecting: return "Looking for glasses..."
        case .searching: return "Registering..."
        case .error: return "Connection Failed"
        case .disconnected: return "Not Connected"
        }
    }
}

// MARK: - Assistant & Brain Sections

/// Both assistant sections, rendered with their own glass chrome.
///
/// Deliberately NOT built from `SettingsView.glassSection`. That helper is a
/// generic `@ViewBuilder` method, so calling it from `body` folds its whole
/// content type into `SettingsView.body`'s type. This file already sat at the
/// edge — the commit immediately before this feature was "Fix SettingsView
/// stack overflow by extracting body into computed properties" — and two more
/// `glassSection` calls in `body` pushed it back over, overflowing the Swift
/// runtime's demangler on the resulting type name.
///
/// From `body`'s point of view this is now one plain named type, and the chrome
/// is reproduced locally with a non-generic ViewModifier so nothing nests.
struct AssistantSettingsSections: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                GlassCardHeader(title: "Assistant", icon: "sparkle", color: .cyan)
                AssistantSettingsCard(settings: settings)
                    .modifier(GlassCardChrome())
            }
            VStack(alignment: .leading, spacing: 10) {
                GlassCardHeader(title: "Brain", icon: "brain", color: .indigo)
                BrainSettingsCard(settings: settings)
                    .modifier(GlassCardChrome())
            }
        }
    }
}

// MARK: - Local Glass Chrome

private struct GlassCardHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }
}

/// Non-generic on purpose: `ViewModifier.Content` is opaque, so wrapping a card
/// in this does not grow the caller's type the way a generic container would.
private struct GlassCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.12, blue: 0.16))
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
    }
}

// MARK: - Assistant Settings Card
//
// Broken out of SettingsView as real View types rather than inline builders.
// Inlining these rows into `glassSection`'s generic @ViewBuilder produced a
// single deeply-nested generic type that overflowed the stack when evaluated.
// Each small struct here is its own type with its own body, which caps the
// nesting depth and keeps the stack flat.

private struct AssistantSettingsCard: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggleRow(
                label: "Assistant Mode",
                icon: "circle.hexagongrid.fill",
                isOn: $settings.assistantEnabled
            )
            SettingsRowDivider()

            AssistantNameRow(name: $settings.assistantName)
            SettingsRowDivider()

            assistantToggles

            SettingsFooterText(
                "Assistant Mode makes the orb your home screen — the camera becomes a mode it can enter. "
                + "Wake Word listens on-device for your assistant's name and never sends audio anywhere "
                + "until you ask something. \"Let It Use the Camera\" lets it take a look on its own when "
                + "a question needs eyes."
            )
        }
    }

    /// Grouped so the parent's stack stays short.
    @ViewBuilder
    private var assistantToggles: some View {
        SettingsToggleRow(label: "Wake Word", icon: "waveform", isOn: $settings.wakeWordEnabled)
        SettingsRowDivider()
        SettingsToggleRow(label: "Speak While Streaming", icon: "text.bubble", isOn: $settings.streamingSpeechEnabled)
        SettingsRowDivider()
        SettingsToggleRow(label: "Let It Use the Camera", icon: "eye", isOn: $settings.brainCanRequestVision)
    }
}

// MARK: - Brain Settings Card

private struct BrainSettingsCard: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkerURLRow(url: $settings.brainBaseURL)
            SettingsRowDivider()
            WorkerTokenRow(token: $settings.brainAPIToken)

            SettingsFooterText(
                "Optional. The Cloudflare Worker adds persistent memory plus weather and calendar context. "
                + "Leave both blank and the assistant runs directly against your Claude key — it just "
                + "forgets between sessions. See worker/README.md to deploy."
            )
        }
    }
}

// MARK: - Rows

private struct AssistantNameRow: View {
    @Binding var name: String

    var body: some View {
        HStack {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)
            Text("Name")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            TextField("Jarvis", text: $name)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .font(.subheadline)
                .autocorrectionDisabled()
                .frame(maxWidth: 150)
        }
        .padding(.vertical, 8)
    }
}

private struct WorkerURLRow: View {
    @Binding var url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Worker URL")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
            // Plain field rather than a SecureField — the URL isn't a secret,
            // and masking it makes typos impossible to spot.
            TextField("https://jarvis-brain.you.workers.dev", text: $url)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.cyan)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }
}

private struct WorkerTokenRow: View {
    @Binding var token: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Worker Token")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
            SecureField("bearer token", text: $token)
                .textContentType(.password)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.cyan)
        }
    }
}

// MARK: - Shared Row Chrome
//
// Local copies of SettingsView's `glassDivider` / `settingsFooter`, which are
// instance methods and so unreachable from these standalone types.

private struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.vertical, 8)
    }
}

private struct SettingsFooterText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsToggleRow: View {
    let label: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(isOn ? .white : .white.opacity(0.4))
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
        .tint(.cyan)
    }
}

// MARK: - Active Skills List

/// One skill row, as data.
struct SkillRowSpec: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    let status: SkillStatusRow.SkillStatus
    let note: String
    let color: Color
}

/// Renders the skill catalog through a ForEach.
///
/// The point is that this is ONE view type regardless of how many skills the
/// app grows. The previous hand-written version produced a TupleView with a
/// distinct generic parameter per row, and the runtime overflowed its stack
/// resolving the resulting type name.
private struct ActiveSkillsList: View {
    let skills: [SkillRowSpec]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                if index > 0 {
                    SettingsRowDivider()
                }
                SkillCatalogRow(skill: skill)
            }
        }
    }
}

private struct SkillCatalogRow: View {
    let skill: SkillRowSpec

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: skill.icon)
                .foregroundStyle(skill.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(skill.note)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            Text(skill.status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(skill.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(skill.status.color.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 2)
    }
}
