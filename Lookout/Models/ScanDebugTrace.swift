import Foundation

struct ScanDebugTrace {
    let timestamp: Date
    let provider: String
    let imageBytes: Int
    let locationSummary: String
    let ambientDecibels: Double?
    let placeSignalType: String
    let placeSignalEvidence: String?
    
    let rawAIResponse: AIVisionResponse
    let routedAIResponse: AIVisionResponse
    let routingReason: String
    let routingKeyword: String?
    
    let selectedSkill: String
    let skillResultTitle: String
    
    let userContextPrompt: String
    let visionSystemPrompt: String
    
    let narrationProvider: String?
    let narrationSystemPrompt: String?
    let narrationUserPrompt: String?
    let narrationOutput: String?
    
    let currentTitleSeenCount: Int
}
