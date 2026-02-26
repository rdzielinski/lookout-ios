import Foundation
import UIKit

// MARK: - Conversation Message
struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = Date()
    
    enum Role: String {
        case user
        case assistant
    }
}

// MARK: - Conversation Service
class ConversationService {
    
    private let settings: SettingsManager
    private(set) var messages: [ConversationMessage] = []
    private var apiMessages: [[String: Any]] = []
    private var contextImageBase64: String?
    
    // Injected context
    var userContextString: String = ""
    var faceContextString: String = ""
    var placeContextString: String = ""
    
    init(settings: SettingsManager) {
        self.settings = settings
    }
    
    // MARK: - Start Conversation
    
    func startConversation(imageData: Data?, aiResponse: AIVisionResponse?, skillResult: SkillResult?, faceMatches: [FaceMatch] = [], nearbyPlace: SavedPlace? = nil, userQuestion: String? = nil) {
        messages = []
        apiMessages = []
        contextImageBase64 = nil
        
        if let imageData = imageData, let image = UIImage(data: imageData),
           let compressed = image.jpegData(compressionQuality: 0.5) {
            contextImageBase64 = compressed.base64EncodedString()
        }
        
        var contextParts: [String] = []
        
        if let ai = aiResponse {
            contextParts.append("Category: \(ai.category)")
            contextParts.append("Description: \(ai.description)")
        }
        
        if let result = skillResult {
            contextParts.append("Identified as: \(result.title)")
            contextParts.append("Details: \(result.subtitle)")
            for detail in result.details {
                contextParts.append("\(detail.label): \(detail.value)")
            }
            contextParts.append("Source: \(result.sourceApp)")
        }
        
        // Face context
        let recognizedFaces = faceMatches.filter { $0.name != nil }
        if !recognizedFaces.isEmpty {
            let names = recognizedFaces.compactMap { $0.name }
            contextParts.append("People recognized in frame: \(names.joined(separator: ", "))")
        }
        
        // Place context
        if let place = nearbyPlace {
            contextParts.append("User is at: \(place.name) (\(place.category.rawValue))")
        }
        
        // User history context
        if !userContextString.isEmpty {
            contextParts.append("User context:\n\(userContextString)")
        }
        
        let context = contextParts.joined(separator: "\n")
        
        var userContent: [[String: Any]] = []
        
        if let base64 = contextImageBase64 {
            switch settings.selectedProvider {
            case .claude:
                userContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64
                    ]
                ])
            case .openai:
                userContent.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
                ])
            }
        }
        
        var initialText = "I just took a photo and here's what was identified:\n\(context)\n\nYou are now in conversation mode. The user may ask follow-up questions about what they see. Answer conversationally and concisely — you're being spoken aloud, so keep responses to 1-3 sentences. Be helpful, direct, and natural. Use any context about the user to personalize your responses."

        if let question = userQuestion, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialText += "\n\nThe user specifically asked: \"\(question)\". Please answer their question based on what was identified."
        }

        userContent.append([
            "type": "text",
            "text": initialText
        ])
        
        apiMessages.append([
            "role": "user",
            "content": userContent
        ])
        
        // Show user's pre-scan question in the conversation
        if let question = userQuestion, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ConversationMessage(role: .user, text: question))
        }

        let initialSummary = skillResult.map { result in
            "That's \(result.title). \(result.subtitle). \(result.details.prefix(2).map { "\($0.label): \($0.value)" }.joined(separator: ". "))."
        } ?? "I can see something in the image. What would you like to know?"

        apiMessages.append([
            "role": "assistant",
            "content": initialSummary
        ])

        messages.append(ConversationMessage(role: .assistant, text: initialSummary))
    }
    
    // MARK: - Ask Follow-up
    
    func askFollowUp(_ question: String) async throws -> String {
        messages.append(ConversationMessage(role: .user, text: question))
        apiMessages.append([
            "role": "user",
            "content": question
        ])
        
        let response: String
        switch settings.selectedProvider {
        case .claude:
            response = try await askClaude()
        case .openai:
            response = try await askOpenAI()
        }
        
        messages.append(ConversationMessage(role: .assistant, text: response))
        apiMessages.append([
            "role": "assistant",
            "content": response
        ])
        
        return response
    }
    
    // MARK: - Claude
    
    private var systemPrompt: String {
        var prompt = "You are Lookout, a helpful AI camera assistant. You're in a follow-up conversation about something the user just photographed. Keep responses short (1-3 sentences) since they'll be spoken aloud. Be conversational and direct — no filler words, no bullet points."
        
        if !userContextString.isEmpty {
            prompt += "\n\nUser context:\n\(userContextString)"
        }
        
        return prompt
    }
    
    private func askClaude() async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 20
        
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 300,
            "system": systemPrompt,
            "messages": apiMessages
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LookoutError.apiError("Claude API error (\(statusCode))")
        }
        
        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        return claudeResponse.content.first(where: { $0.type == "text" })?.text ?? "Sorry, I couldn't process that."
    }
    
    // MARK: - OpenAI
    
    private func askOpenAI() async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        
        var msgs = apiMessages
        msgs.insert([
            "role": "system",
            "content": systemPrompt
        ], at: 0)
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 300,
            "messages": msgs
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LookoutError.apiError("OpenAI API error (\(statusCode))")
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        return openAIResponse.choices.first?.message.content ?? "Sorry, I couldn't process that."
    }
    
    // MARK: - State
    
    var hasContext: Bool { !apiMessages.isEmpty }
    
    func clear() {
        messages = []
        apiMessages = []
        contextImageBase64 = nil
    }
}
