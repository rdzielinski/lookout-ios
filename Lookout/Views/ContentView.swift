import SwiftUI
import AVFoundation


struct ContentView: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var viewModel = LookoutViewModel()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var followUpText = ""
    @State private var showConversation = false
    @State private var faceNameText = ""
    @State private var faceRelationshipText = ""
    @State private var showSavePlace = false
    @State private var placeNameText = ""
    @State private var selectedPlaceCategory: PlaceCategory = .other
    @AppStorage("hasSeenPrivacyWelcome") private var hasSeenPrivacyWelcome = false
    @AppStorage("developerTraceEnabled") private var developerTraceEnabled = false
    @State private var showDebugTrace = false
    @State private var showPrivacyWelcome = false
    @State private var resultCardOffset = CGSize.zero
    @GestureState private var resultCardDragTranslation = CGSize.zero

    // Atmospheric orb animation
    @State private var orbPhase: Double = 0
    @State private var lastResultCategory: SkillCategory = .unknown

    var body: some View {
        ZStack {
            // MARK: - Camera Feed
            if viewModel.cameraPermissionGranted {
                CameraPreview(session: viewModel.captureSession)
                    .ignoresSafeArea()
            } else {
                noCameraView
            }

            atmosphericOverlay

            // Camera sleeping overlay
            if viewModel.isCameraSleeping {
                VStack(spacing: 16) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Camera Off")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Tap the bolt icon or say \"camera on\" to resume")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.7))
                .transition(.opacity)
                .onTapGesture { viewModel.wakeCamera() }
            }

            // MARK: - Overlay UI
            VStack(spacing: 0) {
                topBar

                // Glasses connection error banner
                if settings.glassesMode && viewModel.glassesService.connectionState == .error,
                   let errorMsg = viewModel.glassesService.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "eyeglasses").font(.caption)
                        Text(errorMsg).font(.caption2).lineLimit(2)
                        Spacer()
                        Button {
                            GlassesService.openBluetoothSettings()
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        Button {
                            viewModel.glassesService.retryConnection()
                        } label: {
                            Text("Retry")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.red.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 6)
                }

                if viewModel.isOfflineMode {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash").font(.caption)
                        Text("Offline Mode").font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.orange.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 6)
                }

                // Continuous scan indicator
                if settings.continuousScanEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .symbolEffect(.rotate, isActive: true)
                        Text("Continuous Scan")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.cyan.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
                }

                Spacer()
                if viewModel.isAudioOnlyMode {
                    audioOnlyOverlay
                } else if viewModel.showResult {
                    resultAndConversationArea
                }
                Spacer()
                // Pre-scan question field
                if !viewModel.isAudioOnlyMode && !viewModel.showResult && !viewModel.isCapturing {
                    preScanQuestionField
                }
                if !viewModel.isAudioOnlyMode { bottomControls }
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.isOfflineMode)
            .animation(.easeInOut(duration: 0.3), value: settings.continuousScanEnabled)
            .animation(.easeInOut(duration: 0.3), value: viewModel.glassesService.connectionState == .error)

            // MARK: - Viewfinder Reticle
            if !viewModel.isAudioOnlyMode && !viewModel.showResult {
                ScanReticleView(isScanning: viewModel.isCapturing)
                    .allowsHitTesting(false)
            }

            // Voice recording overlay
            if !viewModel.isAudioOnlyMode && viewModel.isAskingFollowUp { voiceRecordingOverlay }

            // Face naming overlay
            if !viewModel.isAudioOnlyMode && viewModel.showFaceNaming { faceNamingOverlay }

            // Face detection badges
            if !viewModel.isAudioOnlyMode && viewModel.showResult && !viewModel.currentFaceMatches.isEmpty {
                VStack {
                    HStack {
                        Spacer()
                        faceBadge
                            .padding(.trailing, 20)
                            .padding(.top, 60)
                    }
                    Spacer()
                }
                .transition(.opacity)
                .animation(.easeInOut, value: viewModel.currentFaceMatches.isEmpty)
            }
        }
        .onAppear {
            viewModel.configure(settings: settings)
            viewModel.checkPermissions()
            showPrivacyWelcome = !hasSeenPrivacyWelcome
            startOrbAnimation()
        }
        .onChange(of: viewModel.currentQuery?.skillResult?.category) { _, newCat in
            if let cat = newCat {
                withAnimation(.easeInOut(duration: 1.2)) {
                    lastResultCategory = cat
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(glassesService: viewModel.glassesService) }
        .sheet(isPresented: $showHistory) { ScanHistoryView(viewModel: viewModel) }
        .sheet(isPresented: $showSavePlace) { savePlaceSheet }
        .sheet(isPresented: $showDebugTrace) { ScanDebugView(trace: viewModel.latestDebugTrace) }
        .sheet(isPresented: $showPrivacyWelcome, onDismiss: { hasSeenPrivacyWelcome = true }) {
            PrivacyWelcomeView { hasSeenPrivacyWelcome = true; showPrivacyWelcome = false }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.showResult)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.currentQuery?.id) { _, _ in resultCardOffset = .zero }
        .onChange(of: viewModel.showResult) { _, show in
            if !show { resultCardOffset = .zero }
        }
    }

    // MARK: - Orb Animation
    private func startOrbAnimation() {
        withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
            orbPhase = 1
        }
    }

    // MARK: - Audio-Only Glasses Overlay
    private var audioOnlyOverlay: some View {
        VStack(spacing: 16) {
            switch viewModel.glassesFlowState {
            case .scanning:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
                Text("Analyzing...")
                    .font(.headline)
                    .foregroundStyle(.cyan)
            case .speakingResult, .speakingFollowUp:
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.8))
                    .symbolEffect(.variableColor.iterative)
                Text("Speaking...")
                    .font(.headline)
                    .foregroundStyle(.white)
            case .listeningForFollowUp:
                Image(systemName: "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("Listening...")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Ask a follow-up or wait to return")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            case .processingFollowUp:
                ProgressView()
                    .tint(.white)
                Text("Thinking...")
                    .font(.headline)
                    .foregroundStyle(.white)
            case .cooldown:
                Text("Returning to standby...")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            case .idle:
                Image(systemName: "eyeglasses")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Glasses Active")
                    .font(.headline)
                    .foregroundStyle(.white)
                if settings.glassesCameraButtonEnabled && settings.glassesAutoListen {
                    Text("Press camera button or say \"\(settings.glassesTriggerPhrase)\"")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                } else if settings.glassesCameraButtonEnabled {
                    Text("Press camera button to scan")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Text("Say \"\(settings.glassesTriggerPhrase)\" to scan")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if viewModel.isCapturing {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 8)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.glassesFlowState.rawValue)
    }

    // MARK: - Atmospheric Overlay (category-reactive orbs)
    private var atmosphericOverlay: some View {
        ZStack {
            // Base vignette
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear, Color.black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Top-left orb — shifts color based on last scanned category
            RadialGradient(
                colors: [lastResultCategory.skillColor.opacity(0.22), Color.clear],
                center: .init(x: 0.15 + orbPhase * 0.08, y: 0.08 + orbPhase * 0.04),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: orbPhase)

            // Top-right orb — complementary, slower drift
            RadialGradient(
                colors: [Color.cyan.opacity(0.12 + orbPhase * 0.05), Color.clear],
                center: .init(x: 0.88 - orbPhase * 0.06, y: 0.05 + orbPhase * 0.03),
                startRadius: 0,
                endRadius: 280
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 10).repeatForever(autoreverses: true), value: orbPhase)

            // Bottom ambient glow
            RadialGradient(
                colors: [Color.black.opacity(0.3), Color.clear],
                center: .bottom,
                startRadius: 40,
                endRadius: 360
            )
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            circularControl(icon: "clock.arrow.circlepath", action: { showHistory = true })

            Spacer()

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.18)).frame(width: 22, height: 22)
                    Circle().fill(Color.cyan).frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("LOOKOUT")
                        .font(.caption.weight(.heavy))
                        .tracking(1.8)
                        .fontDesign(.rounded)

                    if settings.glassesMode {
                        HStack(spacing: 4) {
                            Image(systemName: "eyeglasses").font(.caption2).foregroundStyle(glassesStatusColor)

                            if viewModel.glassesService.connectionState == .error {
                                // Show error + tappable retry
                                Button {
                                    viewModel.glassesService.retryConnection()
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("Failed")
                                            .font(.caption2).foregroundStyle(.red)
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.red)
                                    }
                                }
                            } else if let attemptInfo = viewModel.glassesService.connectionAttemptInfo,
                                      viewModel.glassesService.connectionState == .connecting {
                                // Show "Connecting... Attempt 2 of 4"
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(viewModel.glassesService.connectionState.rawValue)
                                        .font(.caption2).foregroundStyle(glassesStatusColor)
                                    Text(attemptInfo)
                                        .font(.system(size: 8)).foregroundStyle(.orange.opacity(0.7))
                                }
                            } else {
                                Text(viewModel.glassesService.connectionState.rawValue)
                                    .font(.caption2).foregroundStyle(glassesStatusColor)
                            }
                        }
                    } else {
                        Text(settings.selectedProvider.rawValue)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer()

            HStack(spacing: 10) {
                // Camera power toggle
                circularControl(
                    icon: viewModel.isCameraSleeping ? "bolt.slash.fill" : "bolt.fill",
                    tint: viewModel.isCameraSleeping ? .red : nil,
                    action: {
                        withAnimation(.spring(response: 0.3)) { viewModel.toggleCameraPower() }
                    }
                )

                // Parking spot
                circularControl(icon: "car.fill", action: {
                    viewModel.saveParkingSpot()
                })

                circularControl(icon: "mappin.circle.fill", action: {
                    placeNameText = ""; selectedPlaceCategory = .other; showSavePlace = true
                })
                circularControl(icon: "camera.rotate.fill", action: {
                    withAnimation(.spring(response: 0.3)) { viewModel.flipCamera() }
                })
                circularControl(icon: "gear", action: { showSettings = true })
                if developerTraceEnabled {
                    circularControl(icon: "ladybug", action: { showDebugTrace = true })
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var glassesStatusColor: Color {
        switch viewModel.glassesService.connectionState {
        case .connected, .streaming: return .green
        case .searching, .connecting: return .orange
        case .disconnected: return .secondary
        case .error: return .red
        }
    }

    // MARK: - Result + Conversation Area
    private var resultAndConversationArea: some View {
        VStack(spacing: 8) {
            if let query = viewModel.currentQuery {
                ResultCardView(
                    query: query,
                    onDismiss: {
                        withAnimation(.spring(response: 0.4)) {
                            resultCardOffset = .zero
                            viewModel.dismissResult()
                            showConversation = false
                        }
                    },
                    onOpenSource: { url in UIApplication.shared.open(url) }
                )
                .offset(
                    x: resultCardOffset.width + resultCardDragTranslation.width,
                    y: resultCardOffset.height + resultCardDragTranslation.height
                )
                .simultaneousGesture(resultCardDragGesture)
                .overlay(alignment: .bottomTrailing) {
                    Text("Drag")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.18), in: Capsule())
                        .padding(.trailing, 18).padding(.bottom, 8)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.currentQuery?.status == .complete {
                conversationArea.transition(.opacity)
            }
        }
        .padding(.bottom, 8)
    }

    private var resultCardDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($resultCardDragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                let proposed = CGSize(
                    width: resultCardOffset.width + value.translation.width,
                    height: resultCardOffset.height + value.translation.height
                )
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    resultCardOffset = clampedCardOffset(proposed)
                }
            }
    }

    private func clampedCardOffset(_ offset: CGSize) -> CGSize {
        let bounds = UIScreen.main.bounds
        let maxX = max(42, bounds.width * 0.30)
        let maxY = max(64, bounds.height * 0.22)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    // MARK: - Conversation Area
    private var conversationArea: some View {
        VStack(spacing: 8) {
            if viewModel.conversationMessages.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(viewModel.conversationMessages.dropFirst()) { message in
                                ConversationBubble(message: message).id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: viewModel.conversationMessages.count) { _, _ in
                        if let lastMessage = viewModel.conversationMessages.last {
                            withAnimation { proxy.scrollTo(lastMessage.id, anchor: .bottom) }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask a follow-up...", text: $followUpText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !followUpText.isEmpty {
                    Button(action: {
                        viewModel.sendFollowUp(followUpText)
                        followUpText = ""
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2).foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Pre-Scan Question
    private var preScanQuestionField: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
            TextField("Ask something...", text: $viewModel.preScanQuestion)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.white)
                .submitLabel(.done)
                .onSubmit {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Bottom Controls
    private var bottomControls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                ornamentButton(
                    icon: settings.voiceOutputEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill",
                    title: "Sound",
                    accent: settings.voiceOutputEnabled ? .cyan : .gray
                ) { settings.voiceOutputEnabled.toggle() }

                if viewModel.showResult && viewModel.currentQuery?.status == .complete {
                    ornamentButton(
                        icon: viewModel.isAskingFollowUp ? "mic.fill" : "mic",
                        title: "Ask",
                        accent: viewModel.isAskingFollowUp ? .red : .mint
                    ) {}
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.2).onEnded { _ in viewModel.interruptAndAsk() })
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in
                        if viewModel.isAskingFollowUp { viewModel.stopAskingAndSend() }
                    })
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ornamentBackground)

            // MARK: - Scan Button
            Button(action: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    viewModel.captureAndAnalyze()
                }
            }) {
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(Color.white.opacity(viewModel.isCapturing ? 0.5 : 0.28), lineWidth: 1.5)
                        .frame(width: 96, height: 96)

                    // Pulsing ring during capture
                    if viewModel.isCapturing {
                        PulsingRing()
                    }

                    // Main disc
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 96, height: 96)

                    Circle()
                        .fill(viewModel.isCapturing ? Color.red : Color.white)
                        .frame(width: 76, height: 76)
                        .scaleEffect(viewModel.isCapturing ? 0.88 : 1.0)
                        .animation(.spring(response: 0.3), value: viewModel.isCapturing)

                    if viewModel.isCapturing {
                        ProgressView().tint(.white).scaleEffect(1.3)
                    } else {
                        Image(systemName: "eye.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.black)
                    }
                }
            }
            .disabled(viewModel.isCapturing)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)

            HStack(spacing: 12) {
                if viewModel.speechService.isSpeaking {
                    ornamentButton(icon: "hand.raised.fill", title: "Interrupt", accent: .orange) {
                        viewModel.interruptAndAsk()
                    }
                } else {
                    ornamentButton(icon: "camera.rotate", title: "Flip", accent: .blue) {
                        viewModel.flipCamera()
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ornamentBackground)
        }
        .padding(.bottom, 32)
        .animation(.spring(response: 0.3), value: viewModel.speechService.isSpeaking)
        .animation(.spring(response: 0.3), value: viewModel.showResult)
    }

    private var ornamentBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
    }

    private func ornamentButton(icon: String, title: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.88))
            }
        }
    }

    // MARK: - Voice Recording Overlay
    private var voiceRecordingOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.2)).frame(width: 100, height: 100)
                        .scaleEffect(viewModel.isAskingFollowUp ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: viewModel.isAskingFollowUp)
                    Image(systemName: "mic.fill").font(.system(size: 36)).foregroundStyle(.red)
                }
                Text("Listening...").font(.headline).foregroundStyle(.white)
                if !viewModel.voiceInput.transcript.isEmpty {
                    Text(viewModel.voiceInput.transcript)
                        .font(.body).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                        .transition(.opacity)
                }
                Button(action: { viewModel.stopAskingAndSend() }) {
                    Text("Tap to Send").font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(.blue).clipShape(Capsule())
                }
                Button(action: { viewModel.voiceInput.stopListening(); viewModel.isAskingFollowUp = false }) {
                    Text("Cancel").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 32).padding(.bottom, 120)
        }
        .background(Color.black.opacity(0.4)).ignoresSafeArea()
        .transition(.opacity)
    }

    // MARK: - Circular Control
    @ViewBuilder
    private func circularControl(icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint ?? .white)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Face Badge
    private var faceBadge: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(0..<viewModel.currentFaceMatches.count, id: \.self) { index in
                let face = viewModel.currentFaceMatches[index]
                if let name = face.name {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                        Text(name).font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                }
            }
            let unknownCount = viewModel.currentFaceMatches.filter { $0.isNew }.count
            if unknownCount > 0 {
                Button {
                    faceNameText = ""; faceRelationshipText = ""
                    withAnimation(.spring(response: 0.3)) { viewModel.showFaceNaming = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                        Text("\(unknownCount) new face\(unknownCount > 1 ? "s" : "")").font(.caption.weight(.medium))
                        Image(systemName: "plus.circle.fill").font(.caption).foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                }
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Face Naming Overlay
    private var faceNamingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { viewModel.skipFaceNaming() }
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.blue.opacity(0.15)).frame(width: 72, height: 72)
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 32)).foregroundStyle(.blue)
                    }
                    Text("New Face Detected").font(.headline)
                    Text("Name this person so Lookout can recognize them next time.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("e.g. Alexis", text: $faceNameText)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Relationship (optional)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("e.g. Wife, Coworker, Student", text: $faceRelationshipText)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                HStack(spacing: 12) {
                    Button { withAnimation { viewModel.skipFaceNaming() } } label: {
                        Text("Skip").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        let name = faceNameText.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        withAnimation {
                            viewModel.saveNewFace(name: name, relationship: faceRelationshipText.trimmingCharacters(in: .whitespaces))
                            faceNameText = ""; faceRelationshipText = ""
                        }
                    } label: {
                        Text("Save Face").fontWeight(.semibold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(faceNameText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.blue.opacity(0.4) : Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(faceNameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .padding(.horizontal, 32)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Save Place Sheet
    private var savePlaceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Place name", text: $placeNameText)
                    Picker("Category", selection: $selectedPlaceCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Label(category.rawValue, systemImage: category.iconName).tag(category)
                        }
                    }
                } header: { Text("Save Current Location") }
                footer: {
                    if let loc = viewModel.locationManager.currentLocation {
                        Text("GPS: \(String(format: "%.4f", loc.coordinate.latitude)), \(String(format: "%.4f", loc.coordinate.longitude))")
                    } else { Text("Waiting for GPS location...") }
                }
            }
            .navigationTitle("Save Place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSavePlace = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = placeNameText.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        viewModel.saveCurrentPlace(name: name, category: selectedPlaceCategory)
                        placeNameText = ""; selectedPlaceCategory = .other; showSavePlace = false
                    }
                    .disabled(placeNameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - No Camera View
    private var noCameraView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "camera.fill").font(.system(size: 48)).foregroundStyle(.gray)
                Text("Camera access is required").font(.headline).foregroundStyle(.white)
                Text("Go to Settings → Lookout → Camera").font(.subheadline).foregroundStyle(.gray)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Scan Reticle View
struct ScanReticleView: View {
    let isScanning: Bool

    @State private var cornerScale: CGFloat = 1.0
    @State private var cornerOpacity: Double = 0.6
    @State private var flashOpacity: Double = 0.0
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Corner brackets
            ReticleCorners(contracted: isScanning)
                .stroke(
                    Color.white.opacity(cornerOpacity),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: isScanning ? 200 : 240, height: isScanning ? 200 : 240)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isScanning)

            // Center dot
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 6, height: 6)
                .scaleEffect(pulseScale)

            // Flash on complete
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 240, height: 240)
                .opacity(flashOpacity)

            // Hint label
            if !isScanning {
                VStack {
                    Spacer()
                    Text("Point at something and tap the eye")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.bottom, 220)
                }
            }
        }
        .onChange(of: isScanning) { _, scanning in
            if scanning {
                // Contract + pulse
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    cornerOpacity = 0.9
                    pulseScale = 1.6
                }
            } else {
                // Flash white on complete
                withAnimation(.easeOut(duration: 0.15)) { flashOpacity = 0.8 }
                withAnimation(.easeOut(duration: 0.4).delay(0.15)) { flashOpacity = 0.0 }
                withAnimation(.spring(response: 0.3)) { cornerOpacity = 0.6; pulseScale = 1.0 }
            }
        }
    }
}

// MARK: - Reticle Corner Shape
struct ReticleCorners: Shape {
    var contracted: Bool
    private let length: CGFloat = 28
    private let inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: inset, dy: inset)

        // Top-left
        path.move(to: CGPoint(x: r.minX, y: r.minY + length))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        // Top-right
        path.move(to: CGPoint(x: r.maxX - length, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        // Bottom-right
        path.move(to: CGPoint(x: r.maxX, y: r.maxY - length))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: r.minX + length, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - length))

        return path
    }
}

// MARK: - Pulsing Ring (scan button)
struct PulsingRing: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(opacity), lineWidth: 2)
            .frame(width: 96, height: 96)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    scale = 1.35; opacity = 0
                }
            }
    }
}

// MARK: - Conversation Bubble
struct ConversationBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(Color(red: 0.17, green: 0.44, blue: 0.93))
                            : AnyShapeStyle(.ultraThinMaterial)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(message.timestamp, style: .time)
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: 280, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer() }
        }
    }
}

#Preview {
    ContentView().environmentObject(SettingsManager())
}
