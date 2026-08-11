import Foundation
import AVFoundation

// MARK: - Voice Engine
enum VoiceEngine: String, CaseIterable, Codable {
    case elevenLabs = "ElevenLabs"
    case apple = "Apple (On-Device)"
}

// MARK: - ElevenLabs Voice
struct ElevenLabsVoice: Identifiable, Codable, Hashable {
    let id: String       // voice_id for API
    let name: String     // display name
    let category: String // premade, cloned, etc.
    
    // Popular built-in voices
    static let presets: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", category: "premade"),
        ElevenLabsVoice(id: "AZnzlk1XvdvUeBnXmlld", name: "Domi", category: "premade"),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Bella", category: "premade"),
        ElevenLabsVoice(id: "ErXwobaYiN019PkySvjV", name: "Antoni", category: "premade"),
        ElevenLabsVoice(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", category: "premade"),
        ElevenLabsVoice(id: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", category: "premade"),
        ElevenLabsVoice(id: "VR6AewLTigWG4xSOukaG", name: "Arnold", category: "premade"),
        ElevenLabsVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", category: "premade"),
        ElevenLabsVoice(id: "yoZ06aMxZJJ28mfd3POQ", name: "Sam", category: "premade"),
        ElevenLabsVoice(id: "jBpfuIE2acCO8z3wKNLl", name: "Emily", category: "premade"),
        ElevenLabsVoice(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", category: "premade"),
        ElevenLabsVoice(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", category: "premade"),
    ]
}

// MARK: - Apple Voice Style (kept for fallback)
enum VoiceStyle: String, CaseIterable, Codable {
    case zoe = "Zoe"
    case samantha = "Samantha"
    case aaron = "Aaron"
    case nicky = "Nicky"
    case evan = "Evan"
    case system = "System Default"
    
    var voiceIdentifiers: [String] {
        switch self {
        case .zoe:
            return [
                "com.apple.voice.premium.en-US.Zoe",
                "com.apple.voice.enhanced.en-US.Zoe",
                "com.apple.voice.compact.en-US.Zoe",
                "com.apple.ttsbundle.siri_Nicky_en-US_compact",
            ]
        case .samantha:
            return [
                "com.apple.voice.premium.en-US.Samantha",
                "com.apple.voice.enhanced.en-US.Samantha",
                "com.apple.voice.compact.en-US.Samantha",
            ]
        case .aaron:
            return [
                "com.apple.voice.premium.en-US.Aaron",
                "com.apple.voice.enhanced.en-US.Aaron",
                "com.apple.voice.compact.en-US.Aaron",
            ]
        case .nicky:
            return [
                "com.apple.voice.premium.en-US.Nicky",
                "com.apple.voice.enhanced.en-US.Nicky",
                "com.apple.voice.compact.en-US.Nicky",
                "com.apple.ttsbundle.siri_Nicky_en-US_compact",
            ]
        case .evan:
            return [
                "com.apple.voice.premium.en-US.Evan",
                "com.apple.voice.enhanced.en-US.Evan",
                "com.apple.voice.compact.en-US.Evan",
            ]
        case .system:
            return []
        }
    }
}

// MARK: - Speech Service
class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var elevenLabsTask: Task<Void, Never>?
    
    @Published var isSpeaking = false
    @Published var selectedVoice: VoiceStyle = .zoe
    @Published var availableEnhancedVoices: [String] = []
    
    // ElevenLabs settings (stored in SettingsManager, referenced here)
    var voiceEngine: VoiceEngine = .apple
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = ElevenLabsVoice.presets.first?.id ?? ""

    /// One-shot callback fired when TTS finishes (Apple or ElevenLabs)
    var onSpeechFinished: (() -> Void)?
    
    override init() {
        super.init()
        synthesizer.delegate = self
        catalogAvailableVoices()
    }
    
    // MARK: - Voice Discovery
    
    func catalogAvailableVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let englishPremium = voices.filter { voice in
            voice.language.hasPrefix("en") &&
            (voice.quality == .enhanced || voice.quality == .premium)
        }
        availableEnhancedVoices = englishPremium.map {
            "\($0.name) [\($0.quality == .premium ? "Premium" : "Enhanced")] — \($0.identifier)"
        }
    }
    
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        for identifier in selectedVoice.voiceIdentifiers {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let premium = voices.first(where: { $0.language.hasPrefix("en-US") && $0.quality == .premium }) {
            return premium
        }
        if let enhanced = voices.first(where: { $0.language.hasPrefix("en-US") && $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
    
    // MARK: - Speak (routes to engine)
    
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        stop()

        if voiceEngine == .elevenLabs && !elevenLabsAPIKey.isEmpty {
            speakWithElevenLabs(text)
        } else {
            speakWithApple(text)
        }
    }

    /// Speak with a one-shot completion callback
    func speak(_ text: String, onFinished: (() -> Void)?) {
        self.onSpeechFinished = onFinished
        speak(text)
    }

    /// Speak and return only once playback has finished.
    ///
    /// `speak(_:)` calls `stop()` on entry, so back-to-back calls cut each other
    /// off. The assistant's streaming TTS queue needs to speak sentence N+1
    /// *after* sentence N, so it awaits this instead.
    ///
    /// The timeout is a deadlock guard: if a completion callback is ever lost
    /// (a cancelled ElevenLabs fetch, an interrupted session), the queue must
    /// still drain rather than wedging the assistant in `.speaking` forever.
    /// It's sized generously off text length so it never truncates real speech.
    func speakAndWait(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timeout = min(60.0, 4.0 + Double(trimmed.count) * 0.09)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeGuard()

            Task { @MainActor in
                self.speak(trimmed) {
                    if resumed.claim() { continuation.resume() }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if resumed.claim() { continuation.resume() }
            }
        }
    }

    /// Serializes the two racers above so the continuation resumes exactly once.
    private final class ResumeGuard: @unchecked Sendable {
        private var claimed = false
        private let lock = NSLock()

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
    
    func speakSegments(_ segments: [String]) {
        let combined = segments.joined(separator: " ")
        guard !combined.isEmpty else { return }
        stop()
        
        if voiceEngine == .elevenLabs && !elevenLabsAPIKey.isEmpty {
            // ElevenLabs sounds better with full text (natural pauses)
            speakWithElevenLabs(combined)
        } else {
            speakSegmentsWithApple(segments)
        }
    }
    
    func stop() {
        elevenLabsTask?.cancel()
        elevenLabsTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Fire any pending completion callback so callers don't get stuck
        let callback = onSpeechFinished
        onSpeechFinished = nil
        callback?()
    }
    
    // MARK: - ElevenLabs TTS
    
    private func speakWithElevenLabs(_ text: String) {
        configureAudioSession()
        
        Task { @MainActor in
            isSpeaking = true
        }
        
        elevenLabsTask = Task {
            do {
                let audioData = try await fetchElevenLabsAudio(text: text)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        let callback = self.onSpeechFinished
                        self.onSpeechFinished = nil
                        callback?()
                    }
                    return
                }

                await MainActor.run {
                    do {
                        self.audioPlayer = try AVAudioPlayer(data: audioData)
                        self.audioPlayer?.delegate = self
                        self.audioPlayer?.play()
                    } catch {
                        #if DEBUG
                        print("⚠️ ElevenLabs playback error: \(error), falling back to Apple")
                        #endif
                        // Fallback to Apple voice
                        self.speakWithApple(text)
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run {
                        let callback = self.onSpeechFinished
                        self.onSpeechFinished = nil
                        callback?()
                    }
                    return
                }
                #if DEBUG
                print("⚠️ ElevenLabs API error: \(error), falling back to Apple")
                #endif
                await MainActor.run {
                    self.speakWithApple(text)
                }
            }
        }
    }
    
    private func fetchElevenLabsAudio(text: String, retries: Int = 1) async throws -> Data {
        let voiceId = elevenLabsVoiceId.isEmpty ? (ElevenLabsVoice.presets.first?.id ?? "") : elevenLabsVoiceId
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.apiError("Invalid ElevenLabs URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.3,
                "use_speaker_boost": true
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LookoutError.apiError("Invalid response from ElevenLabs")
        }
        
        if httpResponse.statusCode == 200 {
            return data
        }
        
        // Parse error
        let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
        
        if httpResponse.statusCode == 429 && retries > 0 {
            // Rate limited — wait and retry once
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await fetchElevenLabsAudio(text: text, retries: retries - 1)
        }
        
        throw LookoutError.apiError("ElevenLabs (\(httpResponse.statusCode)): \(errorMsg)")
    }
    
    // MARK: - Apple TTS (fallback)
    
    private func speakWithApple(_ text: String) {
        configureAudioSession()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.15
        utterance.postUtteranceDelay = 0.1
        
        isSpeaking = true
        synthesizer.speak(utterance)
    }
    
    private func speakSegmentsWithApple(_ segments: [String]) {
        guard !segments.isEmpty else { return }
        configureAudioSession()
        isSpeaking = true
        
        let voice = resolveVoice()
        
        for (index, segment) in segments.enumerated() {
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            
            let utterance = AVSpeechUtterance(string: segment)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            utterance.volume = 1.0
            utterance.pitchMultiplier = index == 0 ? 1.08 : 1.03
            utterance.preUtteranceDelay = index == 0 ? 0.2 : 0.4
            utterance.postUtteranceDelay = index == segments.count - 1 ? 0.1 : 0.05
            
            synthesizer.speak(utterance)
        }
    }
    
    // MARK: - Audio Session
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("⚠️ Audio session config error: \(error)")
            #endif
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = true
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            if !synthesizer.isSpeaking {
                isSpeaking = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                let callback = self.onSpeechFinished
                self.onSpeechFinished = nil
                callback?()
            }
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let callback = self.onSpeechFinished
            self.onSpeechFinished = nil
            callback?()
        }
    }
    
    // MARK: - Category-Aware Speech Builder
    
    func buildSpeechText(from result: SkillResult) -> [String] {
        switch result.category {
        case .flight: return buildFlightSpeech(result)
        case .landmark: return buildLandmarkSpeech(result)
        case .music: return buildMusicSpeech(result)
        case .plant: return buildPlantSpeech(result)
        case .vehicle: return buildVehicleSpeech(result)
        case .product: return buildProductSpeech(result)
        default: return buildGenericSpeech(result)
        }
    }
    
    private func buildFlightSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []

        // Build a rich intro using FR24 data when available
        let detailMap = Dictionary(result.details.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })

        let airline = detailMap["Airline"]
        let route = detailMap["Route"]
        let aircraft = detailMap["Aircraft"]

        // Title: "That's United 456" or "That's Flight UA456"
        segments.append("That's \(result.title).")

        // Airline + aircraft type: "A United Airlines Boeing 737"
        if let airline = airline, let aircraft = aircraft {
            segments.append("A \(airline) \(aircraft).")
        } else if let airline = airline {
            segments.append("Operated by \(airline).")
        } else if let aircraft = aircraft {
            segments.append("It's a \(aircraft).")
        }

        // Route: "Flying from JFK to LAX"
        if let route = route {
            segments.append("Flying \(route.replacingOccurrences(of: "→", with: "to")).")
        }

        // Flight details: altitude, speed, heading
        var detailParts: [String] = []
        for detail in result.details {
            switch detail.label {
            case "Origin Country" where airline == nil:
                detailParts.append("registered in \(detail.value)")
            case "Altitude": detailParts.append("at \(detail.value)")
            case "Speed": detailParts.append("doing \(detail.value)")
            case "Heading": detailParts.append("heading \(detail.value)")
            default: break
            }
        }
        if !detailParts.isEmpty {
            segments.append("Currently " + detailParts.joined(separator: ", ") + ".")
        }

        if result.deepLinkURL != nil {
            segments.append("Open FlightRadar for the full route.")
        }
        return segments
    }
    
    private func buildLandmarkSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []
        segments.append("That looks like \(result.title).")
        if !result.subtitle.isEmpty && result.subtitle != result.title {
            segments.append(result.subtitle + ".")
        }
        for detail in result.details {
            switch detail.label {
            case "Rating": segments.append("It has a \(detail.value) rating.")
            case "Status": segments.append("It's currently \(detail.value.lowercased()).")
            case "Summary":
                let sentences = detail.value.components(separatedBy: ". ")
                let trimmed = sentences.prefix(2).joined(separator: ". ")
                if !trimmed.isEmpty {
                    segments.append(trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
                }
            default: break
            }
        }
        return segments
    }
    
    private func buildMusicSpeech(_ result: SkillResult) -> [String] {
        if result.title == "No Match Found" {
            return ["I couldn't catch that song. Try holding your phone a bit closer to the speaker."]
        }
        var segments: [String] = []
        segments.append("That's \"\(result.title)\" by \(result.subtitle).")
        for detail in result.details {
            if detail.label == "Genre" { segments.append("Genre is \(detail.value).") }
        }
        if result.deepLinkURL != nil {
            segments.append("I can open it in Apple Music if you want.")
        }
        return segments
    }
    
    private func buildPlantSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []
        segments.append("That looks like a \(result.title).")
        if !result.subtitle.isEmpty && result.subtitle != result.title {
            segments.append("Scientifically known as \(result.subtitle).")
        }
        for detail in result.details {
            switch detail.label {
            case "Conservation": segments.append("Heads up — this species is considered \(detail.value.lowercased()).")
            case "Observations": segments.append("There are about \(detail.value) on iNaturalist.")
            case "Summary":
                let sentences = detail.value.components(separatedBy: ". ")
                let trimmed = sentences.prefix(2).joined(separator: ". ")
                if !trimmed.isEmpty { segments.append(trimmed.hasSuffix(".") ? trimmed : trimmed + ".") }
            default: break
            }
        }
        if result.deepLinkURL != nil { segments.append("You can see more on iNaturalist.") }
        return segments
    }
    
    private func buildVehicleSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []
        segments.append("That's a \(result.title).")
        if !result.subtitle.isEmpty && result.subtitle.lowercased() != "vehicle" {
            segments.append("It's a \(result.subtitle.lowercased()).")
        }
        for detail in result.details {
            if detail.label == "Color" { segments.append("\(detail.value) color."); break }
        }
        return segments
    }
    
    private func buildProductSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []
        if result.title == "Product Spotted" {
            return ["I can see a product, but couldn't get the full details."]
        }
        segments.append("That's \(result.title).")
        if !result.subtitle.isEmpty { segments.append("Made by \(result.subtitle).") }
        for detail in result.details {
            switch detail.label {
            case "Nutri-Score": segments.append("It has a Nutri-Score of \(detail.value).")
            case "Size": segments.append("\(detail.value) size.")
            case "Best Price": segments.append("\(detail.value).")
            case "Rating": segments.append("Rated \(detail.value).")
            default: break
            }
        }
        return segments
    }
    
    private func buildGenericSpeech(_ result: SkillResult) -> [String] {
        var segments: [String] = []
        segments.append("I see \(result.title.lowercased()).")
        if !result.subtitle.isEmpty { segments.append(result.subtitle + ".") }
        let useful = result.details.filter { $0.label != "Tip" && $0.label != "Note" }
        for detail in useful.prefix(2) {
            segments.append("\(detail.label): \(detail.value).")
        }
        return segments
    }
}

// MARK: - AVAudioPlayerDelegate
extension SpeechService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let callback = self.onSpeechFinished
            self.onSpeechFinished = nil
            callback?()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            isSpeaking = false
            let callback = self.onSpeechFinished
            self.onSpeechFinished = nil
            callback?()
        }
    }
}
