import Foundation
import CoreLocation

// MARK: - Drink Skill (Wine, Beer, Coffee)
/// Identifies wine, beer, coffee, and specialty beverages from label photos.
/// Uses AI to read the label + Vivino/Untappd-style knowledge for context.
class DrinkSkill: LookoutSkill {
    let category: SkillCategory = .drink
    let displayName: String = "Drink Identifier"
    var requiredAPIKey: String? = nil

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let prompt = """
        You are a beverage expert. Based on this drink description from a photo of a label, \
        provide detailed tasting information. Respond ONLY with JSON:
        {
            "name": "<full product name>",
            "type": "<wine/beer/coffee/spirit/cocktail/other>",
            "producer": "<winery/brewery/roaster>",
            "region": "<origin region/country>",
            "style": "<e.g. Cabernet Sauvignon, IPA, Medium Roast>",
            "vintage_year": "<year if applicable, or empty string>",
            "abv": "<alcohol % if applicable, or empty string>",
            "tasting_notes": "<flavor profile description>",
            "food_pairing": "<suggested food pairings>",
            "rating_estimate": "<estimated rating out of 5 based on general reputation>",
            "price_range": "<typical retail price range>"
        }

        Drink description: \(query)
        """

        let drink = try await analyzeWithAI(prompt: prompt)

        var details: [SkillResult.DetailItem] = []
        details.append(.init(label: "Type", value: drink.style, iconName: "wineglass"))
        if !drink.producer.isEmpty {
            details.append(.init(label: "Producer", value: drink.producer, iconName: "building.2"))
        }
        if !drink.region.isEmpty {
            details.append(.init(label: "Region", value: drink.region, iconName: "globe"))
        }
        if !drink.vintageYear.isEmpty {
            details.append(.init(label: "Vintage", value: drink.vintageYear, iconName: "calendar"))
        }
        if !drink.abv.isEmpty {
            details.append(.init(label: "ABV", value: drink.abv, iconName: "percent"))
        }
        details.append(.init(label: "Tasting Notes", value: drink.tastingNotes, iconName: "nose"))
        details.append(.init(label: "Food Pairing", value: drink.foodPairing, iconName: "fork.knife"))
        if !drink.ratingEstimate.isEmpty {
            details.append(.init(label: "Rating", value: "\(drink.ratingEstimate)/5", iconName: "star"))
        }
        if !drink.priceRange.isEmpty {
            details.append(.init(label: "Price Range", value: drink.priceRange, iconName: "dollarsign.circle"))
        }

        return SkillResult(
            category: .drink,
            title: drink.name,
            subtitle: "\(drink.type.capitalized) — \(drink.style)",
            details: details,
            sourceApp: "Lookout Drinks",
            deepLinkURL: nil
        )
    }

    // MARK: - AI Analysis

    private struct DrinkResponse: Codable {
        let name: String
        let type: String
        let producer: String
        let region: String
        let style: String
        let vintage_year: String
        let abv: String
        let tasting_notes: String
        let food_pairing: String
        let rating_estimate: String
        let price_range: String

        var vintageYear: String { vintage_year }
        var tastingNotes: String { tasting_notes }
        var foodPairing: String { food_pairing }
        var ratingEstimate: String { rating_estimate }
        var priceRange: String { price_range }
    }

    private func analyzeWithAI(prompt: String) async throws -> DrinkResponse {
        switch settings.selectedProvider {
        case .claude:
            return try await callClaude(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt)
        }
    }

    private func callClaude(prompt: String) async throws -> DrinkResponse {
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
            throw LookoutError.apiError("Drink analysis API error")
        }

        let resp = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = resp.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(DrinkResponse.self, from: jsonData)
    }

    private func callOpenAI(prompt: String) async throws -> DrinkResponse {
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
            throw LookoutError.apiError("Drink analysis API error")
        }

        let resp = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let content = resp.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(DrinkResponse.self, from: jsonData)
    }
}
