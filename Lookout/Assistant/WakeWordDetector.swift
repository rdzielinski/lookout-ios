import Foundation
import Speech
import AVFoundation

// MARK: - Wake Word Errors

enum WakeWordError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioUnavailable
    case sessionBusy

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition isn't authorized."
        case .recognizerUnavailable: return "Speech recognizer unavailable."
        case .audioUnavailable: return "Couldn't start the audio engine."
        case .sessionBusy: return "Something else is using the microphone."
        }
    }
}

// MARK: - Wake Word Detector

/// Continuous on-device listening for the assistant's wake phrase.
///
/// Ported from Jarvis with three fixes the merge forced:
///
/// 1. It goes through `AudioSessionCoordinator`, so it yields the mic to
///    dictation, playback, and the glasses trigger instead of racing them.
/// 2. It rebuilds `AVAudioEngine` on every restart. Reusing one engine across
///    Apple Speech's ~60s timeout leaves a stale tap and throws on the second
///    `installTap`.
/// 3. It captures the utterance that *contained* the wake word, so
///    "Jarvis, what's that plane" is handled in one breath rather than making
///    the user wait for a prompt and repeat themselves.
final class WakeWordDetector {

    /// Fires with whatever followed the wake phrase in the same utterance —
    /// empty when the user only said the wake word.
    var onWakeWordDetected: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    /// Wake phrases, longest first so "hey jarvis" matches before "jarvis".
    private var phrases: [String] = ["jarvis"]

    private var isRunning = false
    private var lastDetection: Date = .distantPast
    private let cooldown: TimeInterval = 2.5

    init() {
        // Teardown only — never release from here. This handler runs inside
        // another consumer's `acquire`, and releasing mid-handoff would give
        // ownership straight back.
        AudioSessionCoordinator.shared.register(.wakeWord) { [weak self] in
            self?.isRunning = false
            self?.teardown()
        }
    }

    // MARK: - Authorization

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Lifecycle

    func updatePhrases(_ phrases: [String]) {
        self.phrases = phrases
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    @MainActor
    func start() async throws {
        guard !isRunning else { return }
        guard await Self.requestAuthorization() else { throw WakeWordError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else {
            throw WakeWordError.recognizerUnavailable
        }
        guard AudioSessionCoordinator.shared.acquire(.wakeWord) else {
            throw WakeWordError.sessionBusy
        }

        try startEngine(recognizer: recognizer)
        isRunning = true
    }

    @MainActor
    func stop() {
        isRunning = false
        teardown()
        AudioSessionCoordinator.shared.release(.wakeWord)
    }

    // MARK: - Engine

    private func startEngine(recognizer: SFSpeechRecognizer) throws {
        teardown()

        try AudioSessionCoordinator.shared.configureForRecording()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Wake-word listening runs for as long as the app is open, so keep it
        // on-device: no audio leaves the phone until the user actually asks
        // something, and it doesn't burn network for ambient room noise.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.inspect(result.bestTranscription.formattedString)
            }
            if error != nil || result?.isFinal == true {
                // Apple Speech caps a task at roughly a minute; restart to keep
                // listening. `isRunning` guards against restarting after stop().
                self.scheduleRestart()
            }
        }

        let inputNode = engine.inputNode
        // nil format = use the hardware's native format. Passing an explicit
        // format here is the classic sample-rate-mismatch crash, especially when
        // a Bluetooth route (the glasses) changes underneath us.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw WakeWordError.audioUnavailable
        }
    }

    private func teardown() {
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func scheduleRestart() {
        guard isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard self.isRunning else { return }
            guard let recognizer = self.recognizer, recognizer.isAvailable else { return }
            // Still ours? If something preempted us mid-restart, stay down.
            guard AudioSessionCoordinator.shared.owner == .wakeWord else { return }
            do {
                try self.startEngine(recognizer: recognizer)
            } catch {
                self.isRunning = false
                AudioSessionCoordinator.shared.release(.wakeWord)
            }
        }
    }

    // MARK: - Detection

    private func inspect(_ transcript: String) {
        guard Date().timeIntervalSince(lastDetection) > cooldown else { return }

        let lowered = transcript.lowercased()
        for phrase in phrases {
            guard let range = lowered.range(of: phrase) else { continue }

            // Everything after the wake phrase in this same utterance is the
            // question. Apple gives partial results, so this may be empty on the
            // first hit — the engine handles that by prompting.
            let remainder = String(transcript[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))

            lastDetection = Date()
            let handler = onWakeWordDetected
            Task { @MainActor in
                handler?(remainder)
            }
            return
        }
    }
}
