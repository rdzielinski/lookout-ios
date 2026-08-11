import Foundation

// MARK: - Assistant Intent

/// What the assistant should do with an utterance.
enum AssistantIntent: Equatable {
    /// Needs eyes — capture a frame and run the Lookout vision pipeline.
    /// `question` is carried through so the vision result can be framed as an
    /// answer to what was actually asked, not just a bare skill card.
    case vision(question: String)
    /// Ordinary conversation — send to the brain.
    case chat(question: String)
    /// Handled entirely on-device, no network round trip.
    case control(AssistantCommand)
}

/// Local commands that must never cost a round trip, because they're usually
/// said *because* something is going wrong.
enum AssistantCommand: Equatable {
    case stop
    case cancel
    case newConversation
    case openCamera
    case openSettings
}

// MARK: - Intent Router

/// Classifies an utterance before it costs a network round trip.
///
/// The router is deliberately biased toward `.chat`: a misrouted chat question
/// is a wasted sentence, but a misrouted vision question fires the camera,
/// burns a vision API call, and makes the glasses click for no reason. Anything
/// genuinely ambiguous goes to the brain, which can ask for the camera itself
/// via an `action: "capture"` directive (see `BrainService`).
struct IntentRouter {

    // MARK: - Vocabulary

    /// Pointing words. Vision questions almost always contain one — the user is
    /// referring to something present rather than something known.
    private static let deictics: Set<String> = [
        "this", "that", "these", "those", "here", "it",
    ]

    /// Phrases that mean "use the camera" no matter what follows.
    private static let explicitVisionPhrases: [String] = [
        "what am i looking at", "what do you see", "what are you seeing",
        "look at this", "look at that", "take a look", "have a look",
        "what is this", "what's this", "what is that", "what's that",
        "who is this", "who's this", "who is that", "who's that",
        "check this out", "tell me about this", "tell me about that",
        "scan this", "scan that", "read this", "read that",
        "identify this", "identify that", "what am i seeing",
        "what does this say", "what does that say", "what does this mean",
        "translate this", "translate that",
    ]

    /// Verbs that imply pointing the camera, when paired with a deictic.
    private static let visionVerbs: Set<String> = [
        "look", "see", "scan", "read", "identify", "recognize",
        "photograph", "capture", "watch",
    ]

    /// Nouns that map onto a registered Lookout skill. These only trigger vision
    /// when a deictic is also present — "what's that plane" needs eyes, but
    /// "when was the first plane built" does not.
    private static let skillNouns: Set<String> = [
        // FlightSkill
        "plane", "planes", "jet", "aircraft", "flight", "airplane", "helicopter",
        // LandmarkSkill
        "building", "landmark", "monument", "statue", "church", "tower", "bridge",
        // PlantSkill
        "plant", "flower", "tree", "leaf", "weed", "mushroom", "shrub",
        // VehicleSkill
        "car", "truck", "vehicle", "motorcycle", "suv",
        // BarcodeSkill / PriceLookupService
        "barcode", "label", "price", "product", "sign", "menu", "text",
        // MusicSkill
        "song", "music", "track", "tune",
        // TranslationSkill
        "translate", "translation", "written",
        // FoodSkill
        "food", "dish", "meal", "recipe", "ingredient", "calories",
        // DrinkSkill
        "drink", "wine", "beer", "cocktail", "bottle",
        // ReceiptSkill
        "receipt", "bill", "total",
        // MedicationSkill
        "pill", "medication", "medicine", "prescription", "dosage",
        // BookSkill
        "book", "author", "cover", "novel",
        // BusinessCardSkill
        "card", "contact",
        // QRCodeSkill ("barcode" already covered above)
        "qr",
        // FaceMemoryService
        "person", "face", "guy", "woman", "man",
        // General
        "animal", "dog", "cat", "bird", "bug", "insect",
    ]

    /// Words that mean the question is about knowledge, not the here-and-now,
    /// even if a deictic slipped in ("what's the weather like out there").
    private static let chatAnchors: Set<String> = [
        "weather", "forecast", "temperature", "rain", "snow",
        "schedule", "calendar", "meeting", "appointment", "reminder",
        "score", "game", "brewers", "dockhounds",
        "remind", "text", "email", "call", "message",
        "time", "date", "tomorrow", "yesterday", "tonight",
    ]

    private static let stopPhrases: Set<String> = [
        "stop", "stop talking", "be quiet", "quiet", "shut up", "shush", "enough",
    ]

    private static let cancelPhrases: Set<String> = [
        "cancel", "never mind", "nevermind", "forget it", "forget that", "nothing",
    ]

    private static let newConversationPhrases: Set<String> = [
        "new conversation", "start over", "clear the conversation",
        "forget everything", "fresh start", "reset",
    ]

    private static let cameraPhrases: Set<String> = [
        "open the camera", "open camera", "show me the camera",
        "camera mode", "viewfinder",
    ]

    private static let settingsPhrases: Set<String> = [
        "open settings", "show settings", "open preferences",
    ]

    // MARK: - Classification

    /// Classify an utterance. `hasVisionContext` should be true when the user is
    /// already mid-conversation about something they just scanned — in that case
    /// "what about that one" is a follow-up on the existing frame, not a request
    /// for a new capture.
    static func classify(_ utterance: String, hasVisionContext: Bool = false) -> AssistantIntent {
        let normalized = normalize(utterance)

        guard !normalized.isEmpty else { return .control(.cancel) }

        // 1. Control commands — exact-ish matches only, so "stop by the store"
        //    isn't swallowed.
        if stopPhrases.contains(normalized) { return .control(.stop) }
        if cancelPhrases.contains(normalized) { return .control(.cancel) }
        if newConversationPhrases.contains(where: { normalized == $0 }) {
            return .control(.newConversation)
        }
        if cameraPhrases.contains(where: { normalized.contains($0) }) {
            return .control(.openCamera)
        }
        if settingsPhrases.contains(where: { normalized.contains($0) }) {
            return .control(.openSettings)
        }

        let words = Set(normalized.split(separator: " ").map(String.init))

        // 2. A knowledge anchor wins outright. "What's on my schedule today"
        //    contains no deictic, but "what's the weather like out here" does —
        //    and still isn't a camera question.
        if !words.isDisjoint(with: chatAnchors) {
            return .chat(question: utterance)
        }

        // 3. Explicit vision phrases. If the user is already discussing a frame,
        //    these are follow-ups and belong to the existing conversation.
        if explicitVisionPhrases.contains(where: { normalized.contains($0) }) {
            return hasVisionContext ? .chat(question: utterance) : .vision(question: utterance)
        }

        // 4. Deictic + (vision verb | skill noun). "What kind of tree is that",
        //    "read that sign for me".
        let hasDeictic = !words.isDisjoint(with: deictics)
        if hasDeictic && !hasVisionContext {
            if !words.isDisjoint(with: visionVerbs) || !words.isDisjoint(with: skillNouns) {
                return .vision(question: utterance)
            }
        }

        // 5. Everything else is conversation. The brain can still ask for the
        //    camera if it disagrees.
        return .chat(question: utterance)
    }

    // MARK: - Wake Word Stripping

    /// Remove a leading wake phrase so "Jarvis, what's that plane" reaches the
    /// classifier as "what's that plane". Only strips from the front — a
    /// mid-sentence name is part of the question.
    static func stripWakePhrase(_ utterance: String, phrases: [String]) -> String {
        var result = utterance.trimmingCharacters(in: .whitespacesAndNewlines)

        // Longest first, so "hey jarvis" strips before "jarvis".
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let candidates = ["\(phrase),", "\(phrase)"]
            for candidate in candidates where result.lowercased().hasPrefix(candidate) {
                result = String(result.dropFirst(candidate.count))
                return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            }
        }
        return result
    }

    // MARK: - Normalization

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
