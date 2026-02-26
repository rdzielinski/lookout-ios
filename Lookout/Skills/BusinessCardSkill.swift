import Foundation
import CoreLocation

// MARK: - Business Card / Contact Capture Skill
/// Reads business cards via AI, extracts structured contact info.
class BusinessCardSkill: LookoutSkill {
    let category: SkillCategory = .businessCard
    let displayName: String = "Business Card Scanner"
    var requiredAPIKey: String? = nil

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let prompt = """
        You are a business card reader. Extract all contact information from this card. \
        Respond ONLY with JSON:
        {
            "name": "<full name>",
            "title": "<job title, or empty string>",
            "company": "<company name, or empty string>",
            "email": "<email address, or empty string>",
            "phone": "<phone number, or empty string>",
            "website": "<website URL, or empty string>",
            "address": "<physical address, or empty string>",
            "linkedin": "<LinkedIn URL or handle, or empty string>",
            "other": "<any other info on the card, or empty string>"
        }

        Card text: \(query)
        """

        let contact = try await analyzeWithAI(prompt: prompt)

        var details: [SkillResult.DetailItem] = []
        if !contact.title.isEmpty {
            details.append(.init(label: "Title", value: contact.title, iconName: "briefcase"))
        }
        if !contact.company.isEmpty {
            details.append(.init(label: "Company", value: contact.company, iconName: "building.2"))
        }
        if !contact.email.isEmpty {
            details.append(.init(label: "Email", value: contact.email, iconName: "envelope"))
        }
        if !contact.phone.isEmpty {
            details.append(.init(label: "Phone", value: contact.phone, iconName: "phone"))
        }
        if !contact.website.isEmpty {
            details.append(.init(label: "Website", value: contact.website, iconName: "globe"))
        }
        if !contact.address.isEmpty {
            details.append(.init(label: "Address", value: contact.address, iconName: "mappin"))
        }
        if !contact.linkedin.isEmpty {
            details.append(.init(label: "LinkedIn", value: contact.linkedin, iconName: "link"))
        }
        if !contact.other.isEmpty {
            details.append(.init(label: "Other", value: contact.other, iconName: "info.circle"))
        }

        let subtitle = [contact.title, contact.company].filter { !$0.isEmpty }.joined(separator: " at ")

        return SkillResult(
            category: .businessCard,
            title: contact.name,
            subtitle: subtitle.isEmpty ? "Contact" : subtitle,
            details: details,
            sourceApp: "Lookout Contacts",
            deepLinkURL: nil
        )
    }

    // MARK: - AI Analysis

    private struct ContactResponse: Codable {
        let name: String
        let title: String
        let company: String
        let email: String
        let phone: String
        let website: String
        let address: String
        let linkedin: String
        let other: String
    }

    private func analyzeWithAI(prompt: String) async throws -> ContactResponse {
        switch settings.selectedProvider {
        case .claude:
            return try await callClaude(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt)
        }
    }

    private func callClaude(prompt: String) async throws -> ContactResponse {
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
            throw LookoutError.apiError("Business card API error")
        }

        let resp = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = resp.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(ContactResponse.self, from: jsonData)
    }

    private func callOpenAI(prompt: String) async throws -> ContactResponse {
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
            throw LookoutError.apiError("Business card API error")
        }

        let resp = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let content = resp.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(ContactResponse.self, from: jsonData)
    }
}
