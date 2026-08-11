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
    
    // MARK: - Image Optimization
    /// Downscale + compress to reduce upload size and latency by ~40-60%.
    private func optimizedBase64(from image: UIImage) -> String? {
        let maxDimension: CGFloat = 1024
        let size = image.size
        var targetSize = size
        if max(size.width, size.height) > maxDimension {
            let scale = maxDimension / max(size.width, size.height)
            targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.45)?.base64EncodedString()
    }

    // MARK: - Response Cache
    /// Simple in-memory cache keyed by a truncated image hash to skip re-analysis of identical frames.
    private static var responseCache: [Int: (response: AIVisionResponse, date: Date)] = [:]
    private static let cacheTTL: TimeInterval = 30

    private func cachedResponse(for imageHash: Int) -> AIVisionResponse? {
        guard let entry = Self.responseCache[imageHash],
              Date().timeIntervalSince(entry.date) < Self.cacheTTL else { return nil }
        return entry.response
    }

    private func cacheResponse(_ response: AIVisionResponse, for imageHash: Int) {
        Self.responseCache[imageHash] = (response, Date())
        // Evict old entries
        if Self.responseCache.count > 20 {
            let cutoff = Date().addingTimeInterval(-Self.cacheTTL)
            Self.responseCache = Self.responseCache.filter { $0.value.date > cutoff }
        }
    }

    // MARK: - Main Analysis Method
    func analyzeImage(_ image: UIImage, userQuestion: String? = nil) async throws -> AIVisionResponse {
        guard let base64Image = optimizedBase64(from: image) else {
            throw LookoutError.imageProcessingFailed
        }

        let imageHash = base64Image.prefix(256).hashValue
        if let cached = cachedResponse(for: imageHash) {
            return cached
        }

        let userText = buildUserMessageText(userQuestion: userQuestion)

        let result: AIVisionResponse
        switch settings.selectedProvider {
        case .claude:
            result = try await analyzeWithClaude(base64Image: base64Image, userText: userText)
        case .openai:
            result = try await analyzeWithOpenAI(base64Image: base64Image, userText: userText)
        }

        cacheResponse(result, for: imageHash)
        return result
    }

    // MARK: - Streaming Analysis (returns partial text via callback)
    func analyzeImageStreaming(_ image: UIImage, userQuestion: String? = nil, onPartial: @escaping (String) -> Void) async throws -> AIVisionResponse {
        guard let base64Image = optimizedBase64(from: image) else {
            throw LookoutError.imageProcessingFailed
        }

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
            "category": "<one of: flight, landmark, music, plant, vehicle, product, translation, food, drink, receipt, medication, book, businessCard, qrCode, unknown>",
            "description": "<brief description of what you see>",
            "query": "<specific search query for the downstream service>",
            "confidence": <0.0 to 1.0>
        }

        Category guidelines:
        - "flight": Any aircraft in the sky, airplane, helicopter, drone.
        - "landmark": Buildings, monuments, bridges, structures, storefronts, signs.
        - "music": ONLY when music is actively being played/performed (live concert, DJ, now-playing screen). \
        NOT for headphones, instruments not being played, album art, or music equipment.
        - "plant": Plants AND animals (birds, insects, wildlife, pets). Describe animals explicitly.
        - "vehicle": Cars, trucks, motorcycles, boats, bicycles. Include make/model/color if visible.
        - "product": Consumer products, barcodes, packaged goods, electronics, wearable tech.
        - "translation": Foreign-language text, signs, menus, or documents in a non-English language. \
        For query, include the visible text and the language if identifiable.
        - "food": A plate of food, a meal, a dish, prepared food (NOT packaged food products — those are "product"). \
        For query, describe the dishes and ingredients visible.
        - "drink": Wine bottles, beer labels, coffee bags, cocktails, specialty beverages with labels. \
        For query, include the brand/name, type, and any vintage/varietal visible on the label.
        - "receipt": Paper receipts, invoices, bills, price tags with totals. \
        For query, include the store name and total if readable.
        - "medication": Pill bottles, medicine boxes, prescription labels, supplement containers. \
        For query, include the drug/supplement name and dosage if visible.
        - "book": Book covers, movie posters, DVD/Blu-ray cases, game covers. \
        For query, include the title and author/director if visible.
        - "businessCard": Business cards, name tags, contact information cards. \
        For query, include the name, company, and any contact details visible.
        - "qrCode": QR codes (NOT standard barcodes — those are "product"). \
        For query, describe where the QR code appears.
        - "unknown": Anything that doesn't fit the above categories.

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
        request.timeoutInterval = 20

        // Use Haiku for fast classification routing; saves ~1-2s vs Opus.
        let model = settings.useFastModel ? "claude-haiku-4-5-20251001" : "claude-opus-5"

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
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

        // Opus 5 thinks by default and thinking tokens come out of max_tokens,
        // which would leave nothing for the JSON we need back. Haiku doesn't
        // take this parameter, so only send it on the Opus path.
        if !settings.useFastModel {
            body["thinking"] = ["type": "disabled"]
        }

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
            "model": "claude-opus-5",
            "max_tokens": 500,
            // Streaming description — thinking off so the first text_delta
            // arrives immediately instead of behind a reasoning pass.
            "thinking": ["type": "disabled"],
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
