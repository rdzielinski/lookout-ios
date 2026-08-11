import Foundation

// MARK: - Assistant State
///
/// The single state machine for the combined app. Jarvis contributed the voice
/// loop states (idle → listening → processing → speaking); Lookout contributed
/// `looking`, which covers the camera-capture-and-analyze pipeline. They are one
/// machine now because both compete for the microphone and the speaker.
enum AssistantState: Equatable {
    /// Nothing running. Tap the orb or say the wake word.
    case idle
    /// Passively listening on-device for the wake word only.
    case wakeWordListening
    /// Actively transcribing a question.
    case listening
    /// Waiting on the brain.
    case thinking
    /// Capturing a frame and running the vision pipeline (AI → skill router).
    case looking
    /// Speaking a reply.
    case speaking
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "Tap to speak"
        case .wakeWordListening: return "Listening…"
        case .listening: return "Go ahead"
        case .thinking: return "Thinking…"
        case .looking: return "Taking a look…"
        case .speaking: return "Speaking…"
        case .error(let message): return message
        }
    }

    /// True while the assistant is mid-turn and shouldn't be interrupted by
    /// wake-word restarts or background triggers.
    var isBusy: Bool {
        switch self {
        case .listening, .thinking, .looking, .speaking: return true
        case .idle, .wakeWordListening, .error: return false
        }
    }

    /// True when a tap should cancel rather than start something.
    var isCancellable: Bool {
        switch self {
        case .thinking, .looking, .speaking: return true
        default: return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
