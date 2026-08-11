import Foundation
import CoreLocation

// MARK: - Food / Nutrition Skill
/// Analyzes photos of prepared food/meals and estimates calories and macros using AI.
/// No external API needed — uses the existing AI provider for structured nutrition estimates.
class FoodSkill: LookoutSkill {
    let category: SkillCategory = .food
    let displayName: String = "Food & Nutrition"
    var requiredAPIKey: String? = nil

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let prompt = """
        You are a nutrition estimation assistant. Based on this food description from a photo, \
        estimate the nutritional content. Be realistic — give ranges if uncertain. \
        Respond ONLY with JSON:
        {
            "dish_name": "<name of the dish>",
            "estimated_calories": "<e.g. 450-600>",
            "protein_g": "<e.g. 25-30>",
            "carbs_g": "<e.g. 40-55>",
            "fat_g": "<e.g. 18-25>",
            "fiber_g": "<e.g. 5-8>",
            "health_notes": "<brief health note, e.g. 'High protein, moderate carbs'>",
            "ingredients": "<comma-separated key ingredients>"
        }

        Food description: \(query)
        """

        let nutrition = try await analyzeWithAI(prompt: prompt)

        var details: [SkillResult.DetailItem] = []
        details.append(.init(label: "Calories", value: "\(nutrition.estimatedCalories) kcal", iconName: "flame"))
        details.append(.init(label: "Protein", value: "\(nutrition.proteinG)g", iconName: "figure.strengthtraining.traditional"))
        details.append(.init(label: "Carbs", value: "\(nutrition.carbsG)g", iconName: "leaf.circle"))
        details.append(.init(label: "Fat", value: "\(nutrition.fatG)g", iconName: "drop.circle"))
        if !nutrition.fiberG.isEmpty {
            details.append(.init(label: "Fiber", value: "\(nutrition.fiberG)g", iconName: "circle.grid.cross"))
        }
        details.append(.init(label: "Key Ingredients", value: nutrition.ingredients, iconName: "list.bullet"))
        if !nutrition.healthNotes.isEmpty {
            details.append(.init(label: "Health Note", value: nutrition.healthNotes, iconName: "heart"))
        }

        return SkillResult(
            category: .food,
            title: nutrition.dishName,
            subtitle: "\(nutrition.estimatedCalories) kcal estimated",
            details: details,
            sourceApp: "Lookout Nutrition",
            deepLinkURL: nil
        )
    }

    // MARK: - AI Analysis

    private struct NutritionResponse: Codable {
        let dish_name: String
        let estimated_calories: String
        let protein_g: String
        let carbs_g: String
        let fat_g: String
        let fiber_g: String
        let health_notes: String
        let ingredients: String

        var dishName: String { dish_name }
        var estimatedCalories: String { estimated_calories }
        var proteinG: String { protein_g }
        var carbsG: String { carbs_g }
        var fatG: String { fat_g }
        var fiberG: String { fiber_g }
        var healthNotes: String { health_notes }
    }

    private func analyzeWithAI(prompt: String) async throws -> NutritionResponse {
        switch settings.selectedProvider {
        case .claude:
            return try await callClaude(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt)
        }
    }

    private func callClaude(prompt: String) async throws -> NutritionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Food analysis API error")
        }

        let resp = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = resp.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(NutritionResponse.self, from: jsonData)
    }

    private func callOpenAI(prompt: String) async throws -> NutritionResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Food analysis API error")
        }

        let resp = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let content = resp.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(NutritionResponse.self, from: jsonData)
    }
}
