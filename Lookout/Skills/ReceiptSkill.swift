import Foundation
import CoreLocation

// MARK: - Receipt / Expense Skill
/// Reads receipts, extracts merchant/total/items, and logs expenses locally.
class ReceiptSkill: LookoutSkill {
    let category: SkillCategory = .receipt
    let displayName: String = "Receipt Scanner"
    var requiredAPIKey: String? = nil

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let prompt = """
        You are a receipt reader. Extract information from this receipt text. \
        Respond ONLY with JSON:
        {
            "merchant": "<store/restaurant name>",
            "date": "<date if visible, or empty string>",
            "total": "<total amount>",
            "subtotal": "<subtotal before tax, or empty string>",
            "tax": "<tax amount, or empty string>",
            "tip": "<tip amount if applicable, or empty string>",
            "payment_method": "<cash/card type if visible, or empty string>",
            "items": [{"name": "<item>", "price": "<price>"}],
            "category": "<grocery/restaurant/gas/shopping/pharmacy/other>"
        }

        Receipt text: \(query)
        """

        let receipt = try await analyzeWithAI(prompt: prompt)

        // Save to local expense log
        ReceiptStore.shared.addExpense(receipt: receipt, location: location)

        var details: [SkillResult.DetailItem] = []
        details.append(.init(label: "Total", value: receipt.total, iconName: "dollarsign.circle"))
        if !receipt.subtotal.isEmpty {
            details.append(.init(label: "Subtotal", value: receipt.subtotal, iconName: "number"))
        }
        if !receipt.tax.isEmpty {
            details.append(.init(label: "Tax", value: receipt.tax, iconName: "percent"))
        }
        if !receipt.tip.isEmpty {
            details.append(.init(label: "Tip", value: receipt.tip, iconName: "heart"))
        }
        if !receipt.date.isEmpty {
            details.append(.init(label: "Date", value: receipt.date, iconName: "calendar"))
        }
        if !receipt.paymentMethod.isEmpty {
            details.append(.init(label: "Payment", value: receipt.paymentMethod, iconName: "creditcard"))
        }
        details.append(.init(label: "Category", value: receipt.category.capitalized, iconName: "tag"))

        let itemSummary = receipt.items.prefix(5).map { "\($0.name): \($0.price)" }.joined(separator: ", ")
        if !itemSummary.isEmpty {
            details.append(.init(label: "Items", value: itemSummary, iconName: "list.bullet"))
        }

        // Monthly total from store
        let monthlyTotal = ReceiptStore.shared.monthlyTotal()
        details.append(.init(label: "This Month", value: String(format: "$%.2f", monthlyTotal), iconName: "chart.bar"))

        return SkillResult(
            category: .receipt,
            title: receipt.merchant,
            subtitle: "Total: \(receipt.total)",
            details: details,
            sourceApp: "Lookout Expenses",
            deepLinkURL: nil
        )
    }

    // MARK: - AI Analysis

    private func analyzeWithAI(prompt: String) async throws -> ReceiptResponse {
        switch settings.selectedProvider {
        case .claude:
            return try await callClaude(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt)
        }
    }

    private func callClaude(prompt: String) async throws -> ReceiptResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 600,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Receipt analysis API error")
        }

        let resp = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let text = resp.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(ReceiptResponse.self, from: jsonData)
    }

    private func callOpenAI(prompt: String) async throws -> ReceiptResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 600,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookoutError.apiError("Receipt analysis API error")
        }

        let resp = try JSONDecoder().decode(OpenAIAPIResponse.self, from: data)
        guard let content = resp.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw LookoutError.parsingFailed
        }
        return try JSONDecoder().decode(ReceiptResponse.self, from: jsonData)
    }
}

// MARK: - Receipt Response Model

struct ReceiptResponse: Codable {
    let merchant: String
    let date: String
    let total: String
    let subtotal: String
    let tax: String
    let tip: String
    let payment_method: String
    let items: [ReceiptItem]
    let category: String

    var paymentMethod: String { payment_method }

    struct ReceiptItem: Codable {
        let name: String
        let price: String
    }
}

// MARK: - Receipt Store (Local Expense Ledger)

class ReceiptStore {
    static let shared = ReceiptStore()

    private let storageURL: URL
    private(set) var expenses: [ExpenseEntry] = []

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("lookout_expenses.json")
        load()
    }

    struct ExpenseEntry: Codable, Identifiable {
        let id: UUID
        let merchant: String
        let total: Double
        let category: String
        let date: Date
        let latitude: Double?
        let longitude: Double?
        let items: [String]
    }

    func addExpense(receipt: ReceiptResponse, location: CLLocation?) {
        let totalNum = Double(receipt.total.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)) ?? 0
        let entry = ExpenseEntry(
            id: UUID(),
            merchant: receipt.merchant,
            total: totalNum,
            category: receipt.category,
            date: Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            items: receipt.items.map { $0.name }
        )
        expenses.insert(entry, at: 0)
        if expenses.count > 500 { expenses = Array(expenses.prefix(500)) }
        save()
    }

    func monthlyTotal() -> Double {
        let cal = Calendar.current
        let now = Date()
        return expenses
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.total }
    }

    func totalByCategory(month: Date = Date()) -> [String: Double] {
        let cal = Calendar.current
        var result: [String: Double] = [:]
        for e in expenses where cal.isDate(e.date, equalTo: month, toGranularity: .month) {
            result[e.category, default: 0] += e.total
        }
        return result
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            expenses = try JSONDecoder().decode([ExpenseEntry].self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to load expenses: \(error)")
            #endif
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(expenses)
            try data.write(to: storageURL)
        } catch {
            #if DEBUG
            print("⚠️ Failed to save expenses: \(error)")
            #endif
        }
    }
}
