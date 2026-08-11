import Foundation
import AVFoundation

// MARK: - Audio Consumer

/// Every subsystem in the merged app that wants the microphone or the speaker.
/// Before the merge these coexisted only by luck — Lookout's glasses voice
/// trigger and Jarvis's wake-word detector both install a tap on
/// `AVAudioEngine.inputNode` and both call `setActive(true)`, which throws or
/// silently deafens whichever one starts second.
enum AudioConsumer: String, CaseIterable {
    /// Continuous on-device wake-word listening (lowest priority — always yields).
    case wakeWord
    /// The glasses' trigger-phrase listener.
    case glassesTrigger
    /// Speaking a reply (ElevenLabs playback or Apple TTS).
    case playback
    /// Capturing a frame — briefly needs the session for shutter and haptics.
    case visionCapture
    /// Actively transcribing a user question (highest priority — never preempted).
    case dictation

    /// Higher wins. A consumer can only preempt one strictly below it.
    var priority: Int {
        switch self {
        case .wakeWord: return 0
        case .glassesTrigger: return 1
        case .playback: return 2
        case .visionCapture: return 3
        case .dictation: return 4
        }
    }
}

// MARK: - Audio Session Coordinator

/// Serializes access to the shared audio session so exactly one consumer owns
/// the mic at a time.
///
/// Consumers register a teardown handler once, then call `acquire` before
/// touching `AVAudioEngine`/`AVAudioSession` and `release` when finished. When a
/// higher-priority consumer acquires, the current owner's handler fires
/// synchronously so it can remove its tap before the new owner installs one.
///
/// Deliberately *not* `@MainActor`: it's called from `LookoutViewModel`
/// (main-isolated), from `SpeechService` (unisolated), and from audio callbacks.
/// Making it main-isolated would force `assumeIsolated` at several call sites,
/// which crashes rather than degrades if the assumption is ever wrong. A lock is
/// the honest tool here.
final class AudioSessionCoordinator: @unchecked Sendable {

    static let shared = AudioSessionCoordinator()

    private let lock = NSRecursiveLock()
    private var _owner: AudioConsumer?
    private var revokeHandlers: [AudioConsumer: () -> Void] = [:]
    private var idleHandler: (() -> Void)?

    private init() {}

    /// Whoever currently holds the session, if anyone.
    var owner: AudioConsumer? {
        lock.lock()
        defer { lock.unlock() }
        return _owner
    }

    // MARK: - Registration

    /// Register (or replace) the teardown handler for a consumer. The handler
    /// must synchronously stop that consumer's audio engine and remove its tap.
    func register(_ consumer: AudioConsumer, onRevoke: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        revokeHandlers[consumer] = onRevoke
    }

    /// Called when the session drains, so ambient wake-word listening can resume
    /// without every caller having to remember to restart it.
    func onIdle(_ handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        idleHandler = handler
    }

    // MARK: - Acquire / Release

    /// Take ownership, preempting a lower-priority owner. Returns false if a
    /// higher- or equal-priority consumer already holds it, in which case the
    /// caller must not start its engine.
    @discardableResult
    func acquire(_ consumer: AudioConsumer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let current = _owner {
            if current == consumer { return true }
            guard consumer.priority > current.priority else { return false }
            revokeHandlers[current]?()
        }
        _owner = consumer
        return true
    }

    /// Give up the session. No-op unless `consumer` is the current owner, so a
    /// late release from a preempted consumer can't clobber the new owner.
    func release(_ consumer: AudioConsumer) {
        lock.lock()
        let wasOwner = (_owner == consumer)
        if wasOwner { _owner = nil }
        let handler = idleHandler
        lock.unlock()

        // Fire outside the lock — the idle handler restarts the wake-word
        // listener, which calls back into acquire().
        if wasOwner { handler?() }
    }

    /// Force everything down. Used when entering the viewfinder or backgrounding,
    /// where a lingering tap causes the loudest failures.
    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        if let current = _owner {
            revokeHandlers[current]?()
        }
        _owner = nil
    }

    // MARK: - Session Configuration

    /// Configure the shared session for recording. Called by whichever consumer
    /// just successfully acquired the mic.
    ///
    /// `.duckOthers` rather than interrupting, so a podcast dips instead of
    /// stopping while the assistant is merely listening.
    func configureForRecording(allowBluetooth: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.duckOthers, .defaultToSpeaker]
        if allowBluetooth {
            // Meta Ray-Bans present as a Bluetooth HFP route; without this the
            // mic silently falls back to the phone.
            options.insert(.allowBluetooth)
        }
        try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Configure for speaking a reply.
    func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Deactivate entirely, letting other apps' audio return to full volume.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
