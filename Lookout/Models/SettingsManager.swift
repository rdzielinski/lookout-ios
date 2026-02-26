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

    // MARK: - Speed & New Features
    @AppStorage("useFastModel") var useFastModel: Bool = true
    @AppStorage("continuousScanEnabled") var continuousScanEnabled: Bool = false
    @AppStorage("continuousScanInterval") var continuousScanInterval: Double = 8.0
    @AppStorage("proactiveNarrationEnabled") var proactiveNarrationEnabled: Bool = true
    @AppStorage("replayBufferEnabled") var replayBufferEnabled: Bool = true
    @AppStorage("cameraAutoSleepEnabled") var cameraAutoSleepEnabled: Bool = true
    @AppStorage("cameraAutoSleepDelay") var cameraAutoSleepDelay: Double = 120  // seconds, 0 = disabled

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