import SwiftUI

// MARK: - Assistant View

/// The app's home screen after the merge: the orb, not the viewfinder.
///
/// The camera is still one tap away and completely unchanged — it's now a mode
/// the assistant can enter (or be sent to by voice) rather than the front door.
struct AssistantView: View {
    @EnvironmentObject var settings: SettingsManager

    /// The host itself publishes nothing — it's just a container. The two
    /// objects that actually drive this view have to be observed directly, or
    /// the orb never redraws.
    let host: AssistantHost
    @ObservedObject private var engine: AssistantEngine
    @ObservedObject private var glasses: GlassesService

    @State private var showCamera = false
    @State private var showSettings = false
    @State private var showTranscript = false
    @State private var typedMessage = ""
    @FocusState private var typingFocused: Bool

    init(host: AssistantHost) {
        self.host = host
        self.engine = host.engine
        self.glasses = host.viewModel.glassesService
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                orbSection
                Spacer()
                captionSection
                bottomBar
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            engine.requestCameraMode = { showCamera = true }
            engine.requestSettings = { showSettings = true }
            engine.onAppear()
        }
        .onDisappear { engine.onDisappear() }
        .fullScreenCover(isPresented: $showCamera) {
            ContentView(viewModel: host.viewModel)
                .environmentObject(settings)
                .overlay(alignment: .topLeading) { cameraDismissButton }
        }
        .sheet(isPresented: $showSettings, onDismiss: { engine.settingsChanged() }) {
            SettingsView(glassesService: host.viewModel.glassesService)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showTranscript) { transcriptSheet }
        .onChange(of: showCamera) { _, isShowing in
            // The viewfinder owns the mic while it's up (voice trigger,
            // follow-up dictation). Stand the assistant down rather than let
            // two speech recognizers race.
            if isShowing { engine.stopEverything() }
            else if settings.wakeWordEnabled { engine.startWakeWordListening() }
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.02, green: 0.03, blue: 0.07),
                Color(red: 0.01, green: 0.01, blue: 0.03),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 14) {
            statusPill

            Spacer()

            Button { showTranscript = true } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(engine.messages.isEmpty ? 0.3 : 0.75))
            }
            .disabled(engine.messages.isEmpty)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.top, 8)
    }

    /// Shows what the assistant is connected to at a glance: brain, calendar,
    /// glasses. All three are optional, so silence here is normal.
    private var statusPill: some View {
        HStack(spacing: 8) {
            if let reachable = engine.brainReachable {
                indicator(
                    systemName: "brain",
                    active: reachable,
                    label: reachable ? "Brain online" : "Brain unreachable"
                )
            }
            if engine.isCalendarConnected {
                indicator(systemName: "calendar", active: true, label: "Calendar connected")
            }
            if glasses.isGlassesConnected {
                indicator(systemName: "eyeglasses", active: true, label: "Glasses connected")
            }
        }
    }

    private func indicator(systemName: String, active: Bool, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.cyan.opacity(0.85) : Color.orange.opacity(0.8))
            .padding(6)
            .background(Circle().fill(.white.opacity(0.06)))
            .accessibilityLabel(label)
    }

    // MARK: - Orb

    private var orbSection: some View {
        VStack(spacing: 26) {
            Button {
                engine.toggle()
            } label: {
                OrbView(state: engine.state, audioLevel: engine.audioLevel)
            }
            .buttonStyle(.plain)

            Text(engine.state.displayText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(engine.state.isError ? Color.red.opacity(0.9) : .white.opacity(0.55))
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.2), value: engine.state)
        }
    }

    // MARK: - Caption

    /// The live line under the orb: what the user is saying, or what the
    /// assistant is currently saying back.
    @ViewBuilder
    private var captionSection: some View {
        let caption = engine.state == .listening ? engine.currentTranscript : engine.currentSentence

        Text(caption)
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
            .padding(.horizontal, 8)
            .animation(.easeInOut(duration: 0.15), value: caption)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 16) {
            typeRow

            HStack(spacing: 34) {
                wakeWordButton

                Button {
                    showCamera = true
                } label: {
                    controlIcon("camera.viewfinder", active: false)
                }
                .accessibilityLabel("Open camera")

                Button {
                    engine.clearConversation()
                } label: {
                    controlIcon("arrow.counterclockwise", active: false)
                }
                .disabled(engine.messages.isEmpty)
                .opacity(engine.messages.isEmpty ? 0.35 : 1)
                .accessibilityLabel("New conversation")
            }
            .padding(.bottom, 12)
        }
    }

    private var wakeWordButton: some View {
        Button {
            settings.wakeWordEnabled.toggle()
            engine.settingsChanged()
        } label: {
            controlIcon(
                settings.wakeWordEnabled ? "waveform.circle.fill" : "waveform.circle",
                active: settings.wakeWordEnabled
            )
        }
        .accessibilityLabel(settings.wakeWordEnabled
            ? "Wake word on. Say \(settings.assistantName)."
            : "Wake word off")
    }

    private func controlIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 23, weight: .regular))
            .foregroundStyle(active ? Color.cyan : .white.opacity(0.6))
            .frame(width: 52, height: 52)
            .background(Circle().fill(.white.opacity(active ? 0.10 : 0.05)))
    }

    /// Typing is the fallback for anywhere you can't talk.
    private var typeRow: some View {
        HStack(spacing: 10) {
            TextField("Type instead…", text: $typedMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .focused($typingFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Capsule().fill(.white.opacity(0.07)))

            if !typedMessage.isEmpty {
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.cyan)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: typedMessage.isEmpty)
    }

    private func sendTyped() {
        let text = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedMessage = ""
        typingFocused = false
        engine.send(text: text)
    }

    // MARK: - Camera Dismiss

    private var cameraDismissButton: some View {
        Button {
            showCamera = false
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .padding(.leading, 20)
        .padding(.top, 60)
        .accessibilityLabel("Back to assistant")
    }

    // MARK: - Transcript

    private var transcriptSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(engine.messages) { message in
                            TranscriptBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    if let last = engine.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.02, green: 0.03, blue: 0.07).ignoresSafeArea())
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showTranscript = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Transcript Bubble

private struct TranscriptBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                if message.sawSomething {
                    // Marks the turns where the assistant actually used its eyes.
                    Label("Saw it", systemImage: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
                }

                Text(message.text)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white.opacity(isUser ? 0.95 : 0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isUser ? Color.cyan.opacity(0.18) : Color.white.opacity(0.07))
                    )
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}
