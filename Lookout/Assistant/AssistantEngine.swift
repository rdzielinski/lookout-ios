import Foundation
import SwiftUI
import Combine

// MARK: - Vision Provider

/// What a vision scan produced.
struct VisionOutcome {
    /// A short, speakable summary of the skill result — the fast path answer.
    let spokenSummary: String
    /// Structured context for the brain, so follow-up conversation knows what
    /// was seen.
    let context: VisionContext
}

/// The camera half of the app, as the assistant sees it.
///
/// `LookoutViewModel` conforms. Stated as a protocol so the assistant depends on
/// the capability rather than on 1,400 lines of camera/session/glasses code, and
/// so the orb UI can be driven in previews without a capture session.
@MainActor
protocol VisionProvider: AnyObject {
    /// Camera or glasses available and permissioned.
    var isVisionReady: Bool { get }
    /// Capture a frame and run the full analyze → route → skill pipeline.
    /// Throws if capture or analysis fails.
    func runVisionScan(question: String?) async throws -> VisionOutcome
}

// MARK: - Assistant Engine

/// The app's top-level orchestrator: wake word → listen → decide → answer.
///
/// This is where the two projects actually merge. Jarvis contributed the voice
/// loop and the streaming-TTS queue; Lookout contributed the eyes. The engine
/// owns the decision of which one a given utterance needs, and it owns the
/// conversation that spans both — so "what's that plane" and the six follow-up
/// questions after it live in one transcript, with one memory, in one voice.
@MainActor
final class AssistantEngine: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AssistantState = .idle
    @Published private(set) var messages: [ConversationMessage] = []
    /// Live partial transcript while listening.
    @Published var currentTranscript: String = ""
    /// The sentence currently being spoken, for the caption under the orb.
    @Published private(set) var currentSentence: String = ""
    @Published private(set) var isCalendarConnected: Bool = false
    /// nil = not checked yet.
    @Published private(set) var brainReachable: Bool?
    @Published var audioLevel: Float = 0

    var isWakeWordActive: Bool { state == .wakeWordListening }

    // MARK: - Dependencies

    private let settings: SettingsManager
    private let speech: SpeechService
    private let voiceInput: VoiceInputService
    private let haptics: HapticService
    private let brain: BrainService
    private let wakeWord = WakeWordDetector()

    private weak var vision: (any VisionProvider)?
    private var locationText: () -> String? = { nil }
    private var glassesConnected: () -> Bool = { false }

    // MARK: - Conversation

    private var sessionId: String = ""
    /// The last thing the assistant saw, and when. Follow-up questions reuse it
    /// rather than firing the camera again.
    private var lastVision: VisionContext?
    private var lastVisionAt: Date = .distantPast
    /// How long a scan stays "current" for follow-ups.
    private let visionContextTTL: TimeInterval = 3 * 60

    private var hasFreshVision: Bool {
        lastVision != nil && Date().timeIntervalSince(lastVisionAt) < visionContextTTL
    }

    // MARK: - Speech Queue

    private var sentenceQueue: [String] = []
    private var isDraining = false
    private var turnTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?

    // MARK: - Init

    init(settings: SettingsManager, speech: SpeechService, voiceInput: VoiceInputService, haptics: HapticService) {
        self.settings = settings
        self.speech = speech
        self.voiceInput = voiceInput
        self.haptics = haptics
        self.brain = BrainService(settings: settings)

        restoreSession()

        wakeWord.updatePhrases(settings.wakePhrases)
        wakeWord.onWakeWordDetected = { [weak self] trailing in
            self?.handleWakeWord(trailing: trailing)
        }

        // When every other consumer lets go of the mic, ambient listening
        // resumes on its own — this is what makes wake word feel always-on
        // without each code path remembering to restart it.
        AudioSessionCoordinator.shared.onIdle { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.wakeWordEnabled, !self.state.isBusy else { return }
                self.startWakeWordListening()
            }
        }
    }

    /// Connect the camera half. Called once the view model exists.
    func attach(
        vision: any VisionProvider,
        locationText: @escaping () -> String?,
        glassesConnected: @escaping () -> Bool
    ) {
        self.vision = vision
        self.locationText = locationText
        self.glassesConnected = glassesConnected
    }

    // MARK: - Lifecycle

    func onAppear() {
        Task {
            brainReachable = settings.isBrainConfigured ? await brain.checkHealth() : nil
            isCalendarConnected = await brain.checkCalendarStatus()
        }
        if settings.wakeWordEnabled {
            startWakeWordListening()
        }
    }

    func onDisappear() {
        stopEverything()
    }

    /// Re-read settings that affect live subsystems. Called when Settings closes.
    func settingsChanged() {
        wakeWord.updatePhrases(settings.wakePhrases)

        if settings.wakeWordEnabled, state == .idle {
            startWakeWordListening()
        } else if !settings.wakeWordEnabled, state == .wakeWordListening {
            wakeWord.stop()
            state = .idle
        }

        Task {
            brainReachable = settings.isBrainConfigured ? await brain.checkHealth() : nil
            isCalendarConnected = await brain.checkCalendarStatus()
        }
    }

    // MARK: - Wake Word

    func startWakeWordListening() {
        guard settings.wakeWordEnabled, !state.isBusy else { return }
        state = .wakeWordListening
        Task {
            do {
                try await wakeWord.start()
            } catch {
                // Most likely the mic is busy or permission was denied. Fall
                // back to tap-to-talk rather than nagging.
                state = .idle
            }
        }
    }

    private func handleWakeWord(trailing: String) {
        guard state == .wakeWordListening else { return }
        haptics.listeningForFollowUp()
        wakeWord.stop()

        // "Jarvis, what's that plane" arrives as one utterance — answer it
        // immediately instead of making the user say it twice.
        let question = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.count >= 3 {
            currentTranscript = question
            handle(utterance: question)
        } else {
            beginListening()
        }
    }

    // MARK: - Listening

    /// Tap-the-orb entry point.
    func toggle() {
        switch state {
        case .idle, .wakeWordListening:
            beginListening()
        case .listening:
            finishListening()
        case .thinking, .looking, .speaking:
            cancelTurn()
        case .error:
            state = .idle
            beginListening()
        }
    }

    func beginListening() {
        guard !state.isBusy || state == .listening else { return }

        speech.stop()
        wakeWord.stop()
        currentTranscript = ""
        currentSentence = ""
        state = .listening

        do {
            try voiceInput.startListening()
            haptics.recordingStarted()
            startSilenceWatchdog()
        } catch {
            state = .error("Microphone unavailable")
            returnToRest(after: 2)
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        listenTask?.cancel()
        listenTask = nil

        let transcript = voiceInput.stopAndGetTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            returnToRest()
            return
        }

        haptics.recordingSent()
        handle(utterance: transcript)
    }

    /// Auto-submit once the user stops talking, so hands-free actually is.
    private func startSilenceWatchdog() {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }

            var lastLength = 0
            var quietTicks = 0
            let tick: UInt64 = 250_000_000          // 0.25s
            let silenceLimit = 6                     // ~1.5s of no new words
            let maxTicks = 120                       // 30s hard cap

            for _ in 0..<maxTicks {
                try? await Task.sleep(nanoseconds: tick)
                if Task.isCancelled { return }
                guard self.state == .listening else { return }

                let transcript = self.voiceInput.transcript
                self.currentTranscript = transcript

                if transcript.count == lastLength {
                    // Only count silence once they've actually said something.
                    if !transcript.isEmpty { quietTicks += 1 }
                } else {
                    lastLength = transcript.count
                    quietTicks = 0
                }

                if quietTicks >= silenceLimit {
                    self.finishListening()
                    return
                }
            }

            if self.state == .listening { self.finishListening() }
        }
    }

    // MARK: - Turn Handling

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handle(utterance: trimmed)
    }

    private func handle(utterance raw: String) {
        let utterance = IntentRouter.stripWakePhrase(raw, phrases: settings.wakePhrases)
        guard !utterance.isEmpty else {
            returnToRest()
            return
        }

        let intent = IntentRouter.classify(utterance, hasVisionContext: hasFreshVision)

        switch intent {
        case .control(let command):
            perform(command)

        case .vision(let question):
            messages.append(ConversationMessage(role: .user, text: question, sawSomething: true))
            runTurn { try await self.answerWithEyes(question: question) }

        case .chat(let question):
            messages.append(ConversationMessage(role: .user, text: question))
            runTurn { try await self.answerWithBrain(question: question, visionContext: self.freshVisionContext()) }
        }
    }

    private func runTurn(_ work: @escaping () async throws -> Void) {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work()
            } catch is CancellationError {
                // User cancelled — no complaint needed.
            } catch {
                await self.fail(with: error)
            }
        }
    }

    // MARK: - Vision Path

    /// The user asked about something in front of them. Capture, analyze, answer.
    private func answerWithEyes(question: String) async throws {
        guard let vision, vision.isVisionReady else {
            throw AssistantError.visionUnavailable
        }

        state = .looking
        haptics.capturePressed()

        let outcome = try await vision.runVisionScan(question: question)
        lastVision = outcome.context
        lastVisionAt = Date()
        haptics.resultReady()

        try Task.checkCancellation()

        // A bare "what is this" is best answered by the skill card itself: it's
        // already a clean sentence, it's grounded in real API data, and it comes
        // back with no extra round trip. Anything more specific than that
        // deserves a real answer, so hand the frame to the brain.
        if Self.isBareIdentification(question) || !brain.isUsable {
            await speakStreaming(single: outcome.spokenSummary, sawSomething: true)
        } else {
            try await answerWithBrain(question: question, visionContext: outcome.context, sawSomething: true)
        }
    }

    /// True for "what is this"-shaped questions with nothing else attached.
    private static func isBareIdentification(_ question: String) -> Bool {
        let normalized = question.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
        let bare: Set<String> = [
            "what is this", "what's this", "what is that", "what's that",
            "what am i looking at", "what do you see", "what am i seeing",
            "identify this", "identify that", "scan this", "scan that",
            "look at this", "look at that", "take a look", "what is it",
        ]
        return bare.contains(normalized)
    }

    // MARK: - Brain Path

    /// `visionContext`, not `vision` — `vision` is the camera provider property
    /// on this class, and shadowing it here made the capture-retry check below
    /// read as if it were testing whether the camera existed.
    private func answerWithBrain(
        question: String,
        visionContext: VisionContext?,
        sawSomething: Bool = false
    ) async throws {
        guard brain.isUsable else { throw AssistantError.brainUnavailable }

        state = .thinking
        currentSentence = ""
        sentenceQueue.removeAll()

        rotateSessionIfExpired()

        let context = BrainService.snapshot(
            location: locationText(),
            glassesConnected: glassesConnected()
        )

        // The brain can decide mid-answer that it needs to see something.
        // Captured here, acted on after the stream closes so we never interleave
        // a camera shutter with speech.
        var requestedCapture = false
        var finalText = ""

        if settings.streamingSpeechEnabled {
            try await brain.sendStreaming(
                question,
                sessionId: sessionId,
                context: context,
                vision: visionContext,
                onSentence: { [weak self] sentence in
                    Task { @MainActor in self?.enqueue(sentence) }
                },
                onAction: { action in
                    if action.isCapture { requestedCapture = true }
                },
                onComplete: { text in
                    finalText = text
                }
            )
        } else {
            let response = try await brain.send(
                question,
                sessionId: sessionId,
                context: context,
                vision: visionContext
            )
            finalText = response.response
            if response.action?.isCapture == true { requestedCapture = true }
            enqueue(finalText)
        }

        try Task.checkCancellation()

        // Brain asked for eyes and we haven't already given it a frame this turn.
        if requestedCapture, settings.brainCanRequestVision, visionContext == nil {
            sentenceQueue.removeAll()
            try await answerWithEyes(question: question)
            return
        }

        if !finalText.isEmpty {
            messages.append(
                ConversationMessage(role: .assistant, text: finalText, sawSomething: sawSomething)
            )
        }
        await drainQueue()
    }

    /// Vision context to attach to a plain chat turn, if a recent scan makes it
    /// relevant. Lets "how tall is it" work right after "what's that building".
    private func freshVisionContext() -> VisionContext? {
        hasFreshVision ? lastVision : nil
    }

    // MARK: - Speech Queue

    private func enqueue(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentenceQueue.append(trimmed)

        if !isDraining {
            Task { await drainQueue() }
        }
    }

    /// Speak queued sentences in order. Awaiting each one is what makes
    /// streaming work at all — `SpeechService.speak` interrupts itself, so
    /// firing sentences as they arrive would leave only the last one audible.
    private func drainQueue() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        AudioSessionCoordinator.shared.acquire(.playback)
        syncVoice()

        while !sentenceQueue.isEmpty {
            if Task.isCancelled { break }
            let sentence = sentenceQueue.removeFirst()

            state = .speaking
            currentSentence = sentence
            audioLevel = 0.55

            await speech.speakAndWait(sentence)
        }

        audioLevel = 0
        currentSentence = ""
        AudioSessionCoordinator.shared.release(.playback)

        if state == .speaking { returnToRest() }
    }

    private func speakStreaming(single text: String, sawSomething: Bool) async {
        messages.append(ConversationMessage(role: .assistant, text: text, sawSomething: sawSomething))
        enqueue(text)
        await drainQueue()
    }

    /// Push the user's current voice choice into the shared speech service.
    /// Both halves of the app speak through one `SpeechService` instance, so
    /// this has to happen before each turn rather than once at init.
    private func syncVoice() {
        speech.voiceEngine = settings.voiceEngine
        speech.elevenLabsAPIKey = settings.elevenLabsAPIKey
        speech.elevenLabsVoiceId = settings.elevenLabsVoiceId
        speech.selectedVoice = settings.selectedVoiceStyle
    }

    // MARK: - Commands

    private func perform(_ command: AssistantCommand) {
        switch command {
        case .stop:
            speech.stop()
            sentenceQueue.removeAll()
            haptics.interrupted()
            returnToRest()

        case .cancel:
            cancelTurn()

        case .newConversation:
            clearConversation()
            Task { await speakStreaming(single: "Fresh start.", sawSomething: false) }

        case .openCamera:
            requestCameraMode?()
            returnToRest()

        case .openSettings:
            requestSettings?()
            returnToRest()
        }
    }

    /// Set by the view so voice commands can drive navigation.
    var requestCameraMode: (() -> Void)?
    var requestSettings: (() -> Void)?

    func cancelTurn() {
        turnTask?.cancel()
        turnTask = nil
        listenTask?.cancel()
        listenTask = nil
        speech.stop()
        voiceInput.stopListening()
        sentenceQueue.removeAll()
        currentSentence = ""
        audioLevel = 0
        haptics.interrupted()
        returnToRest()
    }

    func stopEverything() {
        cancelTurn()
        wakeWord.stop()
        AudioSessionCoordinator.shared.releaseAll()
        AudioSessionCoordinator.shared.deactivate()
        state = .idle
    }

    func clearConversation() {
        messages.removeAll()
        lastVision = nil
        lastVisionAt = .distantPast
        let old = sessionId
        newSession()
        Task { try? await brain.clearSession(old) }
    }

    // MARK: - Failure

    private func fail(with error: Error) async {
        let message: String
        switch error {
        case AssistantError.visionUnavailable:
            message = "I can't see anything right now — camera isn't ready."
        case AssistantError.brainUnavailable:
            message = "I'm not connected to a brain yet. Add a Worker URL or a Claude key in Settings."
        case let brainError as BrainError:
            message = brainError.errorDescription ?? "Something went wrong."
        default:
            message = "I hit a snag. Try that again?"
        }

        haptics.error()
        messages.append(ConversationMessage(role: .assistant, text: message))
        state = .error(message)

        // Speak the failure — the whole point is hands-free, and a silent error
        // is invisible when the phone is in a pocket and the user is wearing
        // glasses.
        await speakStreaming(single: message, sawSomething: false)
    }

    // MARK: - Rest State

    private func returnToRest(after delay: TimeInterval = 0) {
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self else { return }
            if self.settings.wakeWordEnabled {
                self.state = .idle          // startWakeWordListening sets the real state
                self.startWakeWordListening()
            } else {
                self.state = .idle
                AudioSessionCoordinator.shared.deactivate()
            }
        }
    }

    // MARK: - Session

    private func restoreSession() {
        let started = Date(timeIntervalSince1970: settings.brainSessionStarted)
        if !settings.brainSessionID.isEmpty,
           Date().timeIntervalSince(started) < SettingsManager.brainSessionTimeout {
            sessionId = settings.brainSessionID
        } else {
            newSession()
        }
    }

    private func rotateSessionIfExpired() {
        let started = Date(timeIntervalSince1970: settings.brainSessionStarted)
        if Date().timeIntervalSince(started) >= SettingsManager.brainSessionTimeout {
            newSession()
        }
    }

    private func newSession() {
        sessionId = "s_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
        settings.brainSessionID = sessionId
        settings.brainSessionStarted = Date().timeIntervalSince1970
    }
}

// MARK: - Assistant Errors

enum AssistantError: LocalizedError {
    case visionUnavailable
    case brainUnavailable

    var errorDescription: String? {
        switch self {
        case .visionUnavailable: return "Camera isn't ready."
        case .brainUnavailable: return "No brain configured."
        }
    }
}
