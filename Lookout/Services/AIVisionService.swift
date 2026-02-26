import Foundation
import UIKit

// MARK: - AI Vision Service
class AIVisionService {
    
    private let settings: SettingsManager
    
    init(settings: SettingsManager) {
        self.settings = settings
    }
    
    var debugProviderName: String {
        switch settings.selectedProvider {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        }
    }
    
    var debugSystemPromptText: String { systemPrompt }
    
    // MARK: - Main Analysis Method
    func analyzeImage(_ image: UIImage, userQuestion: String? = nil) async throws -> AIVisionResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw LookoutError.imageProcessingFailed
        }

        let base64Image = imageData.base64EncodedString()
        let userText = buildUserMessageText(userQuestion: userQuestion)

        switch settings.selectedProvider {
        case .claude:
            return try await analyzeWithClaude(base64Image: base64Image, userText: userText)
        case .openai:
            return try await analyzeWithOpenAI(base64Image: base64Image, userText: userText)
        }
    }

    // MARK: - Streaming Analysis (returns partial text via callback)
    func analyzeImageStreaming(_ image: UIImage, userQuestion: String? = nil, onPartial: @escaping (String) -> Void) async throws -> AIVisionResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw LookoutError.imageProcessingFailed
        }

        let base64Image = imageData.base64EncodedString()
        let userText = buildUserMessageText(userQuestion: userQuestion)

        switch settings.selectedProvider {
        case .claude:
            return try await analyzeWithClaudeStreaming(base64Image: base64Image, userText: userText, onPartial: onPartial)
        case .openai:
            return try await analyzeWithOpenAIStreaming(base64Image: base64Image, userText: userText, onPartial: onPartial)
        }
    }

    private func buildUserMessageText(userQuestion: String?) -> String {
        if let question = userQuestion, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The user asks: \"\(question)\". Analyze this image with their question in mind and categorize for routing."
        }
        return "What is this? Analyze and categorize for routing."
    }
    
    // MARK: - System Prompt
    private var systemPrompt: String {
        """
        You are a visual analysis engine for the "Lookout" app. Your job is to look at an image \
        and determine what the user is curious about, then categorize it so the app can route \
        to the correct service/API.
        
        Respond ONLY with valid JSON in this exact format:
        {
            "category": "<one of: flight, landmark, music, plant, vehicle, product, unknown>",
            "description": "<brief description of what you see>",
            "query": "<specific search query for the downstream service>",
            "confidence": <0.0 to 1.0>
        }
        
        Category guidelines:
        - "flight": Any aircraft in the sky, airplane, helicopter, drone. For query, describe \
        the aircraft type, approximate altitude/direction if visible, and any visible markings.
        - "landmark": Buildings, monuments, bridges, structures, storefronts, signs. For query, \
        provide the name if recognizable or a description.
        - "music": ONLY use this category when the image clearly shows music actively being \
        played or performed — such as a live concert, a DJ performing, a TV/speaker currently \
        playing a music video, or a phone/device screen showing a now-playing interface. \
        Do NOT use "music" for headphones, earbuds, instruments not being played, band t-shirts, \
        album art posters, vinyl records, music equipment, speakers that are off, or any \
        music-related objects. Those should be categorized as "product" (for buyable items) \
        or "unknown" (for general music-related things). The "music" category triggers audio \
        listening via Shazam, so only use it when there is likely live audio to identify.
        - "plant": Nature category for plants AND animals (birds, insects, wildlife, pets). \
        Important: if the subject is an animal, describe it explicitly as an animal/bird/pet — \
        do not call it a plant. For query, describe key identifying features like shape, color, \
        size, patterns, markings, habitat cues, or leaf/petal traits when relevant.
        - "vehicle": Cars, trucks, motorcycles, boats, bicycles. For query, include make/model if \
        identifiable, color, year estimate, body type, and distinguishing features.
        - "product": Consumer products, barcodes, QR codes, packaged goods, food items, bottles, \
        cans, electronics, headphones, earbuds, instruments, music equipment, wearable tech. \
        For query, include brand name, product name, or barcode number if visible.
        - "unknown": Anything that doesn't fit the above categories. Use this for general scenes, \
        people, text, documents, clothing, art, or decorative items.
        
        Be specific in your query field — it will be used to search external APIs.
        Do not include any text outside the JSON object.
        """
    }
    
    // MARK: - Claude API (Non-streaming)
    private func analyzeWithClaude(base64Image: String, userText: String) async throws -> AIVisionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 500,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch statusCode {
            case 401: throw LookoutError.apiError("Claude: Invalid API key. Check your key in Settings.")
            case 429: throw LookoutError.apiError("Claude: Rate limit reached. Try again in a moment.")
            case 500...599: throw LookoutError.apiError("Claude: Server error (\(statusCode)). Try again.")
            default:
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw LookoutError.apiError("Claude API error (\(statusCode)): \(errorBody)")
            }
        }
        
        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        
        return try JSONDecoder().decode(AIVisionResponse.self, from: jsonData)
    }
    
    // MARK: - Claude Streaming
    private func analyzeWithClaudeStreaming(base64Image: String, userText: String, onPartial: @escaping (String) -> Void) async throws -> AIVisionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 500,
            "stream": true,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("Claude streaming error")
        }
        
        var fullText = ""
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let lineData = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            
            if let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                fullText += text
                onPartial(fullText)
            }
        }
        
        guard let jsonData = fullText.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        
        return try JSONDecoder().decode(AIVisionResponse.self, from: jsonData)
    }
    
    // MARK: - OpenAI API (Non-streaming)
    private func analyzeWithOpenAI(base64Image: String, userText: String) async throws -> AIVisionResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 500,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch statusCode {
            case 401: throw LookoutError.apiError("OpenAI: Invalid API key. Check your key in Settings.")
            case 429: throw LookoutError.apiError("OpenAI: Rate limit reached. Try again in a moment.")
            case 500...599: throw LookoutError.apiError("OpenAI: Server error (\(statusCode)). Try again.")
            default:
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw LookoutError.apiError("OpenAI API error (\(statusCode)): \(errorBody)")
            }
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let messageContent = openAIResponse.choices.first?.message.content,
              let jsonData = messageContent.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        
        return try JSONDecoder().decode(AIVisionResponse.self, from: jsonData)
    }
    
    // MARK: - OpenAI Streaming
    private func analyzeWithOpenAIStreaming(base64Image: String, userText: String, onPartial: @escaping (String) -> Void) async throws -> AIVisionResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 500,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("OpenAI streaming error")
        }
        
        var fullText = ""
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let lineData = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            
            if let choices = event["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                fullText += content
                onPartial(fullText)
            }
        }
        
        guard let jsonData = fullText.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        
        return try JSONDecoder().decode(AIVisionResponse.self, from: jsonData)
    }
}

// MARK: - Claude API Response Models
struct ClaudeAPIResponse: Codable {
    let content: [ClaudeContent]
    
    struct ClaudeContent: Codable {
        let type: String
        let text: String?
    }
}

// MARK: - OpenAI API Response Models
struct OpenAIAPIResponse: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let message: Message
    }
    
    struct Message: Codable {
        let content: String?
    }
}

// MARK: - Errors
enum LookoutError: LocalizedError {
    case imageProcessingFailed
    case apiError(String)
    case parsingFailed
    case noAPIKey
    case skillNotAvailable
    case networkError(String)
    case offlineNoResult
    
    var errorDescription: String? {
        switch self {
        case .imageProcessingFailed: return "Failed to process image"
        case .apiError(let msg): return msg
        case .parsingFailed: return "Failed to parse AI response"
        case .noAPIKey: return "No API key configured"
        case .skillNotAvailable: return "This skill is not yet available"
        case .networkError(let msg): return "Network error: \(msg)"
        case .offlineNoResult: return "Offline mode couldn't identify this image. Try again with internet."
        }
    }
}
