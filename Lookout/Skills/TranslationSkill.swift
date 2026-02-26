import Foundation
import CoreLocation

// MARK: - Translation Skill
/// Detects foreign-language text in images and translates it using the AI provider.
/// Leverages the existing AI service — no additional API keys needed.
class TranslationSkill: LookoutSkill {
    let category: SkillCategory = .translation
    let displayName: String = "Translation"
    var requiredAPIKey: String? = nil

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        // The query from AI vision contains the detected text and language.
        // We send it to the AI for translation.
        let translationPrompt = """
        Translate the following text to English. If it's already in English, explain what it says. \
        Respond ONLY with JSON: {"source_language": "<detected language>", "original": "<original text>", \
        "translation": "<English translation>", "notes": "<any cultural context or additional info>"}

        Text: \(query)
        """

        let translation = try await translateWithAI(prompt: translationPrompt)

        var details: [SkillResult.DetailItem] = []
        details.append(.init(label: "Original", value: translation.original, iconName: "text.quote"))
        details.append(.init(label: "Language", value: translation.sourceLanguage, iconName: "globe"))
        details.append(.init(label: "Translation", value: translation.translation, iconName: "character.book.closed"))
        if !translation.notes.isEmpty {
            details.append(.init(label: "Notes", value: translation.notes, iconName: "info.circle"))
        }

        return SkillResult(
            category: .translation,
            title: translation.translation,
            subtitle: "\(translation.sourceLanguage) → English",
            details: details,
            sourceApp: "Lookout Translation",
            deepLinkURL: nil
        )
    }

    // MARK: - AI Translation

    private struct TranslationResponse: Codable {
        let source_language: String
        let original: String
        let translation: String
        let notes: String

        var sourceLanguage: String { source_language }
    }

    private func translateWithAI(prompt: String) async throws -> TranslationResponse {
        switch settings.selectedProvider {
        case .claude:
            return try await callClaude(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt)
        }
    }

    private func callClaude(prompt: String) async throws -> TranslationResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 500,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Translation API error")
        }

        let claudeResp = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = claudeResp.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(TranslationResponse.self, from: jsonData)
    }

    private func callOpenAI(prompt: String) async throws -> TranslationResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 500,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Translation API error")
        }

        let oaiResp = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let content = oaiResp.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(TranslationResponse.self, from: jsonData)
    }
}
