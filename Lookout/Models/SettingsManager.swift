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
/// Uses @Published + UserDefaults instead of @AppStorage to avoid
/// SwiftUI re-render storms that cause stack overflow on complex views.
class SettingsManager: ObservableObject {

    private let defaults = UserDefaults.standard

    // MARK: - AI Provider & Keys
    @Published var selectedProvider: AIProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }
    @Published var claudeAPIKey: String {
        didSet { defaults.set(claudeAPIKey, forKey: "claudeAPIKey") }
    }
    @Published var openAIAPIKey: String {
        didSet { defaults.set(openAIAPIKey, forKey: "openAIAPIKey") }
    }

    // MARK: - Voice
    @Published var voiceOutputEnabled: Bool {
        didSet { defaults.set(voiceOutputEnabled, forKey: "voiceOutputEnabled") }
    }
    @Published var selectedVoiceStyle: VoiceStyle {
        didSet { defaults.set(selectedVoiceStyle.rawValue, forKey: "selectedVoiceStyle") }
    }
    @Published var voiceEngine: VoiceEngine {
        didSet { defaults.set(voiceEngine.rawValue, forKey: "voiceEngine") }
    }
    @Published var elevenLabsAPIKey: String {
        didSet { defaults.set(elevenLabsAPIKey, forKey: "elevenLabsAPIKey") }
    }
    @Published var elevenLabsVoiceId: String {
        didSet { defaults.set(elevenLabsVoiceId, forKey: "elevenLabsVoiceId") }
    }
    @Published var elevenLabsVoiceName: String {
        didSet { defaults.set(elevenLabsVoiceName, forKey: "elevenLabsVoiceName") }
    }

    // MARK: - External API Keys
    @Published var adsbExchangeAPIKey: String {
        didSet { defaults.set(adsbExchangeAPIKey, forKey: "adsbExchangeAPIKey") }
    }
    @Published var flightradar24APIKey: String {
        didSet { defaults.set(flightradar24APIKey, forKey: "flightradar24APIKey") }
    }
    @Published var googlePlacesAPIKey: String {
        didSet { defaults.set(googlePlacesAPIKey, forKey: "googlePlacesAPIKey") }
    }

    // MARK: - Intelligence
    @Published var smartNarrationEnabled: Bool {
        didSet { defaults.set(smartNarrationEnabled, forKey: "smartNarrationEnabled") }
    }
    @Published var faceRecognitionEnabled: Bool {
        didSet { defaults.set(faceRecognitionEnabled, forKey: "faceRecognitionEnabled") }
    }
    @Published var placeMemoryEnabled: Bool {
        didSet { defaults.set(placeMemoryEnabled, forKey: "placeMemoryEnabled") }
    }
    @Published var personalContext: String {
        didSet { defaults.set(personalContext, forKey: "personalContext") }
    }
    @Published var developerTraceEnabled: Bool {
        didSet { defaults.set(developerTraceEnabled, forKey: "developerTraceEnabled") }
    }

    // MARK: - Meta Ray-Ban Glasses
    @Published var glassesMode: Bool {
        didSet { defaults.set(glassesMode, forKey: "glassesMode") }
    }
    @Published var glassesTriggerPhrase: String {
        didSet { defaults.set(glassesTriggerPhrase, forKey: "glassesTriggerPhrase") }
    }
    @Published var glassesAutoListen: Bool {
        didSet { defaults.set(glassesAutoListen, forKey: "glassesAutoListen") }
    }
    @Published var audioOnlyGlasses: Bool {
        didSet { defaults.set(audioOnlyGlasses, forKey: "audioOnlyGlasses") }
    }
    @Published var handsFreeChatEnabled: Bool {
        didSet { defaults.set(handsFreeChatEnabled, forKey: "handsFreeChatEnabled") }
    }
    @Published var followUpTimeoutSeconds: Double {
        didSet { defaults.set(followUpTimeoutSeconds, forKey: "followUpTimeoutSeconds") }
    }
    @Published var glassesCameraButtonEnabled: Bool {
        didSet { defaults.set(glassesCameraButtonEnabled, forKey: "glassesCameraButtonEnabled") }
    }

    // MARK: - Speed & New Features
    @Published var useFastModel: Bool {
        didSet { defaults.set(useFastModel, forKey: "useFastModel") }
    }
    @Published var continuousScanEnabled: Bool {
        didSet { defaults.set(continuousScanEnabled, forKey: "continuousScanEnabled") }
    }
    @Published var continuousScanInterval: Double {
        didSet { defaults.set(continuousScanInterval, forKey: "continuousScanInterval") }
    }
    @Published var proactiveNarrationEnabled: Bool {
        didSet { defaults.set(proactiveNarrationEnabled, forKey: "proactiveNarrationEnabled") }
    }
    @Published var replayBufferEnabled: Bool {
        didSet { defaults.set(replayBufferEnabled, forKey: "replayBufferEnabled") }
    }
    @Published var cameraAutoSleepEnabled: Bool {
        didSet { defaults.set(cameraAutoSleepEnabled, forKey: "cameraAutoSleepEnabled") }
    }
    @Published var cameraAutoSleepDelay: Double {
        didSet { defaults.set(cameraAutoSleepDelay, forKey: "cameraAutoSleepDelay") }
    }

    // MARK: - Init

    init() {
        // Load all values from UserDefaults with fallback defaults.
        // Note: didSet is NOT called during init, so no spurious writes.

        self.selectedProvider = defaults.string(forKey: "selectedProvider")
            .flatMap { AIProvider(rawValue: $0) } ?? .claude
        self.claudeAPIKey = defaults.string(forKey: "claudeAPIKey") ?? ""
        self.openAIAPIKey = defaults.string(forKey: "openAIAPIKey") ?? ""

        self.voiceOutputEnabled = defaults.object(forKey: "voiceOutputEnabled") as? Bool ?? true
        self.selectedVoiceStyle = defaults.string(forKey: "selectedVoiceStyle")
            .flatMap { VoiceStyle(rawValue: $0) } ?? .zoe
        self.voiceEngine = defaults.string(forKey: "voiceEngine")
            .flatMap { VoiceEngine(rawValue: $0) } ?? .apple
        self.elevenLabsAPIKey = defaults.string(forKey: "elevenLabsAPIKey") ?? ""
        self.elevenLabsVoiceId = defaults.string(forKey: "elevenLabsVoiceId") ?? "21m00Tcm4TlvDq8ikWAM"
        self.elevenLabsVoiceName = defaults.string(forKey: "elevenLabsVoiceName") ?? "Rachel"

        self.adsbExchangeAPIKey = defaults.string(forKey: "adsbExchangeAPIKey") ?? ""
        self.flightradar24APIKey = defaults.string(forKey: "flightradar24APIKey") ?? ""
        self.googlePlacesAPIKey = defaults.string(forKey: "googlePlacesAPIKey") ?? ""

        self.smartNarrationEnabled = defaults.object(forKey: "smartNarrationEnabled") as? Bool ?? true
        self.faceRecognitionEnabled = defaults.object(forKey: "faceRecognitionEnabled") as? Bool ?? true
        self.placeMemoryEnabled = defaults.object(forKey: "placeMemoryEnabled") as? Bool ?? true
        self.personalContext = defaults.string(forKey: "personalContext") ?? ""
        self.developerTraceEnabled = defaults.object(forKey: "developerTraceEnabled") as? Bool ?? false

        self.glassesMode = defaults.object(forKey: "glassesMode") as? Bool ?? false
        self.glassesTriggerPhrase = defaults.string(forKey: "glassesTriggerPhrase") ?? "lookout"
        self.glassesAutoListen = defaults.object(forKey: "glassesAutoListen") as? Bool ?? true
        self.audioOnlyGlasses = defaults.object(forKey: "audioOnlyGlasses") as? Bool ?? true
        self.handsFreeChatEnabled = defaults.object(forKey: "handsFreeChatEnabled") as? Bool ?? true
        self.followUpTimeoutSeconds = defaults.object(forKey: "followUpTimeoutSeconds") as? Double ?? 12.0
        self.glassesCameraButtonEnabled = defaults.object(forKey: "glassesCameraButtonEnabled") as? Bool ?? true

        self.useFastModel = defaults.object(forKey: "useFastModel") as? Bool ?? true
        self.continuousScanEnabled = defaults.object(forKey: "continuousScanEnabled") as? Bool ?? false
        self.continuousScanInterval = defaults.object(forKey: "continuousScanInterval") as? Double ?? 8.0
        self.proactiveNarrationEnabled = defaults.object(forKey: "proactiveNarrationEnabled") as? Bool ?? true
        self.replayBufferEnabled = defaults.object(forKey: "replayBufferEnabled") as? Bool ?? true
        self.cameraAutoSleepEnabled = defaults.object(forKey: "cameraAutoSleepEnabled") as? Bool ?? true
        self.cameraAutoSleepDelay = defaults.object(forKey: "cameraAutoSleepDelay") as? Double ?? 120
    }

    // MARK: - Computed Helpers

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
