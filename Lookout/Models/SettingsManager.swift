//
//  AIProvider.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


import SwiftUI
import Combine

// MARK: - AI Provider Enum
enum AIProvider: String, CaseIterable, Codable {
    case claude = "Claude (Anthropic)"
    case openai = "GPT-4o (OpenAI)"
    
    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .openai: return "sparkles"
        }
    }
}

// MARK: - Settings Manager
class SettingsManager: ObservableObject {
    @AppStorage("selectedProvider") var selectedProvider: AIProvider = .claude
    @AppStorage("claudeAPIKey") var claudeAPIKey: String = ""
    @AppStorage("openAIAPIKey") var openAIAPIKey: String = ""
    @AppStorage("voiceOutputEnabled") var voiceOutputEnabled: Bool = true
    @AppStorage("selectedVoiceStyle") var selectedVoiceStyle: VoiceStyle = .zoe
    @AppStorage("voiceEngine") var voiceEngine: VoiceEngine = .apple
    @AppStorage("elevenLabsAPIKey") var elevenLabsAPIKey: String = ""
    @AppStorage("elevenLabsVoiceId") var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM"
    @AppStorage("elevenLabsVoiceName") var elevenLabsVoiceName: String = "Rachel"
    @AppStorage("adsbExchangeAPIKey") var adsbExchangeAPIKey: String = ""
    @AppStorage("flightradar24APIKey") var flightradar24APIKey: String = ""
    @AppStorage("googlePlacesAPIKey") var googlePlacesAPIKey: String = ""
    @AppStorage("smartNarrationEnabled") var smartNarrationEnabled: Bool = true
    @AppStorage("faceRecognitionEnabled") var faceRecognitionEnabled: Bool = true
    @AppStorage("placeMemoryEnabled") var placeMemoryEnabled: Bool = true
    @AppStorage("personalContext") var personalContext: String = ""
    @AppStorage("developerTraceEnabled") var developerTraceEnabled: Bool = false
    
    // MARK: - Meta Ray-Ban Glasses
    @AppStorage("glassesMode") var glassesMode: Bool = false
    @AppStorage("glassesTriggerPhrase") var glassesTriggerPhrase: String = "lookout"
    @AppStorage("glassesAutoListen") var glassesAutoListen: Bool = true
    @AppStorage("audioOnlyGlasses") var audioOnlyGlasses: Bool = true
    @AppStorage("handsFreeChatEnabled") var handsFreeChatEnabled: Bool = true
    @AppStorage("followUpTimeoutSeconds") var followUpTimeoutSeconds: Double = 12.0
    @AppStorage("glassesCameraButtonEnabled") var glassesCameraButtonEnabled: Bool = true

    // MARK: - Assistant (Jarvis)
    //
    // Replaces the old `JarvisConfig` static-UserDefaults struct. The assistant
    // is the app's front door; the camera is one of its senses.

    /// What the assistant is called, and what wakes it. Changing this changes
    /// the wake word, the persona name sent to the brain, and the UI label.
    @AppStorage("assistantName") var assistantName: String = "Jarvis"
    /// Master switch. Off = classic Lookout, camera viewfinder as home screen.
    @AppStorage("assistantEnabled") var assistantEnabled: Bool = true
    /// Continuous on-device listening for the wake word.
    @AppStorage("wakeWordEnabled") var wakeWordEnabled: Bool = false
    /// Extra phrases that also wake the assistant, comma-separated.
    @AppStorage("wakeWordAliases") var wakeWordAliases: String = "hey jarvis, okay jarvis"
    /// Let the brain ask for the camera when a question needs eyes.
    @AppStorage("brainCanRequestVision") var brainCanRequestVision: Bool = true
    /// Speak replies sentence-by-sentence as they stream in, rather than
    /// waiting for the full response.
    @AppStorage("streamingSpeechEnabled") var streamingSpeechEnabled: Bool = true

    // MARK: - Brain (Cloudflare Worker)

    /// Worker base URL. Empty = run fully on-device against the Claude API.
    @AppStorage("brainBaseURL") var brainBaseURL: String = ""
    /// Bearer token you generated for the Worker (`openssl rand -hex 32`).
    @AppStorage("brainAPIToken") var brainAPIToken: String = ""
    /// Conversation session id, rotated when a session expires or is cleared.
    @AppStorage("brainSessionID") var brainSessionID: String = ""
    @AppStorage("brainSessionStarted") var brainSessionStarted: Double = 0

    /// Sessions older than this start fresh. Matches the Worker's KV TTL.
    static let brainSessionTimeout: TimeInterval = 4 * 60 * 60

    /// The Worker is only usable once both a URL and a token are present —
    /// a URL alone would just produce 401s.
    var isBrainConfigured: Bool {
        !brainBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !brainAPIToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Normalized Worker URL with any trailing slash removed, so path joins
    /// don't produce `//chat`.
    var normalizedBrainURL: String {
        var url = brainBaseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// Wake phrases, lowercased and de-duplicated: the assistant's name plus
    /// whatever aliases the user added.
    var wakePhrases: [String] {
        let name = assistantName.trimmingCharacters(in: .whitespaces).lowercased()
        let aliases = wakeWordAliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return ([name] + aliases).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var hasValidAPIKey: Bool {
        switch selectedProvider {
        case .claude: return !claudeAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .openai: return !openAIAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    var currentAPIKey: String {
        switch selectedProvider {
        case .claude: return claudeAPIKey.trimmingCharacters(in: .whitespaces)
        case .openai: return openAIAPIKey.trimmingCharacters(in: .whitespaces)
        }
    }
}