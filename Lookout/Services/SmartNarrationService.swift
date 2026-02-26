import Foundation
import UIKit

// MARK: - Smart Narration Service
/// Generates natural, context-aware spoken responses by passing the skill result
/// back through the AI instead of using hard-coded speech templates.
/// This makes every response unique and personalized.
class SmartNarrationService {
    
    private let settings: SettingsManager
    
    init(settings: SettingsManager) {
        self.settings = settings
    }
    
    /// Generate a natural spoken narration for a skill result.
    /// Incorporates user context, face/place info, and conversational tone.
    func generateNarration(
        skillResult: SkillResult,
        aiDescription: String,
        faceMatches: [FaceMatch] = [],
        nearbyPlace: SavedPlace? = nil,
        userContext: String = "",
        currentItemTitle: String = "",
        currentItemRepeatCount: Int? = nil,
        faceRelationships: [String: String] = [:]
    ) async throws -> String {
        let debug = try await generateNarrationDebug(
            skillResult: skillResult,
            aiDescription: aiDescription,
            faceMatches: faceMatches,
            nearbyPlace: nearbyPlace,
            userContext: userContext,
            currentItemTitle: currentItemTitle,
            currentItemRepeatCount: currentItemRepeatCount,
            faceRelationships: faceRelationships
        )
        return debug.outputText
    }

    func generateNarrationDebug(
        skillResult: SkillResult,
        aiDescription: String,
        faceMatches: [FaceMatch] = [],
        nearbyPlace: SavedPlace? = nil,
        userContext: String = "",
        currentItemTitle: String = "",
        currentItemRepeatCount: Int? = nil,
        faceRelationships: [String: String] = [:]
    ) async throws -> NarrationDebugResult {
        let prompt = buildNarrationPrompt(
            skillResult: skillResult,
            aiDescription: aiDescription,
            faceMatches: faceMatches,
            nearbyPlace: nearbyPlace,
            userContext: userContext,
            currentItemTitle: currentItemTitle,
            currentItemRepeatCount: currentItemRepeatCount,
            faceRelationships: faceRelationships
        )
        
        let output: String
        switch settings.selectedProvider {
        case .claude:
            output = try await narrateWithClaude(prompt: prompt)
        case .openai:
            output = try await narrateWithOpenAI(prompt: prompt)
        }
        
        return NarrationDebugResult(
            provider: settings.selectedProvider.rawValue,
            systemPrompt: systemPrompt,
            userPrompt: prompt,
            outputText: output
        )
    }
    
    // MARK: - Build Prompt
    
    private func buildNarrationPrompt(
        skillResult: SkillResult,
        aiDescription: String,
        faceMatches: [FaceMatch],
        nearbyPlace: SavedPlace?,
        userContext: String,
        currentItemTitle: String,
        currentItemRepeatCount: Int?,
        faceRelationships: [String: String] = [:]
    ) -> String {
        
        var contextParts: [String] = []
        
        // What was identified
        contextParts.append("Category: \(skillResult.category.displayName)")
        contextParts.append("Title: \(skillResult.title)")
        contextParts.append("Subtitle: \(skillResult.subtitle)")
        contextParts.append("AI Description: \(aiDescription)")
        if !currentItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextParts.append("Current item title: \(currentItemTitle)")
        }
        if let currentItemRepeatCount {
            contextParts.append("Current item repeat_count: \(currentItemRepeatCount)")
        }
        
        // Skill details
        for detail in skillResult.details {
            contextParts.append("\(detail.label): \(detail.value)")
        }
        contextParts.append("Source: \(skillResult.sourceApp)")
        
        // Face context with relationships
        let recognizedFaces = faceMatches.filter { $0.name != nil }
        if !recognizedFaces.isEmpty {
            let descriptions = recognizedFaces.compactMap { match -> String? in
                guard let name = match.name else { return nil }
                if let relationship = faceRelationships[name], !relationship.isEmpty {
                    return "\(name) (your \(relationship))"
                }
                return name
            }
            contextParts.append("Recognized people in frame: \(descriptions.joined(separator: ", "))")
        }

        let unknownCount = faceMatches.filter { $0.isNew }.count
        if unknownCount > 0 {
            contextParts.append("Unknown faces detected: \(unknownCount). The user can name them by saying \"That's [Name]\".")
        }
        
        // Place context
        if let place = nearbyPlace {
            contextParts.append("User is currently at: \(place.name) (\(place.category.rawValue))")
        }
        
        // User patterns
        if !userContext.isEmpty {
            contextParts.append("User context:\n\(userContext)")
        }
        
        return contextParts.joined(separator: "\n")
    }
    
    // MARK: - System Prompt
    
    private var systemPrompt: String {
        """
        You are Lookout, a smart camera assistant that speaks out loud. You just identified something \
        through the user's phone camera. Generate a natural, conversational spoken response.
        
        RULES:
        - Write EXACTLY how you'd say this out loud — casual, warm, helpful
        - 2-4 short sentences max. This will be spoken by text-to-speech
        - NO bullet points, NO lists, NO markdown, NO asterisks
        - Lead with what it IS, then add the most interesting or useful detail
        - If you recognized a person, greet them by name naturally ("Hey, that's Sarah!")
        - If a recognized person has a relationship (e.g., "your coworker"), use it naturally ("There's your coworker Sarah!")
        - If unknown faces are detected, mention it briefly and naturally ("I see someone I don't recognize" or "There's someone new here")
        - If the user is at a familiar place, acknowledge it casually
        - Only mention repeat/familiarity counts when the prompt explicitly includes `Current item repeat_count` and it is >= 2
        - If `Current item repeat_count` is missing or < 2, do NOT imply repetition
        - Never invent ordinal counts (e.g., second/third/fourth time)
        - Be specific with facts (prices, ratings, species names) but conversational in delivery
        - Don't say "I identified" or "I detected" — just tell them what it is
        - Match energy to content: exciting for discoveries, calm for everyday objects
        - End with something actionable or interesting, not generic ("Nice!" or "There you go!")
        
        EXAMPLES OF GOOD OUTPUT:
        - "That's a Red-tailed Hawk! Pretty common in the Midwest but always impressive. You can tell by the rusty-red tail feathers."
        - "Hey, that's Alexis! Looking good as always."
        - "You're looking at a 2023 Tesla Model Y in white — Long Range trim by the looks of it. Goes for around 45 to 50 thousand."
        - "That's Cheerios — original flavor, 18 ounce box. Nutri-Score A, so pretty solid for a cereal. About 5 bucks at most stores."
        
        EXAMPLES OF BAD OUTPUT:
        - "I have identified a bird in the image. It appears to be a hawk species."
        - "The object is a vehicle. It is a white car."
        - "I see a product with a barcode."
        
        Respond with ONLY the spoken text, nothing else.
        """
    }
    
    // MARK: - Claude Narration
    
    private func narrateWithClaude(prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 200,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("Narration API error")
        }
        
        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        return claudeResponse.content.first(where: { $0.type == "text" })?.text ?? "I see something interesting."
    }
    
    // MARK: - OpenAI Narration
    
    private func narrateWithOpenAI(prompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 200,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("Narration API error")
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        return openAIResponse.choices.first?.message.content ?? "I see something interesting."
    }
}

struct NarrationDebugResult {
    let provider: String
    let systemPrompt: String
    let userPrompt: String
    let outputText: String
}
