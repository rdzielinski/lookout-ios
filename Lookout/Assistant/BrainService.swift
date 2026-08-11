import Foundation
import UIKit

// MARK: - Wire Types

/// What the client knows about the moment, injected into every brain request.
struct ClientContext: Codable {
    let location: String?
    let batteryLevel: Int?
    let localTime: String?
    let timeZone: String?
    let glassesConnected: Bool
}

/// What the assistant just *saw*, when a vision scan preceded the question.
/// This is the payload that turns Jarvis from a voice assistant into one with
/// eyes — the brain gets the structured skill result, not just a caption.
struct VisionContext: Codable {
    let category: String
    let description: String
    let title: String?
    let subtitle: String?
    let details: [String]
    let source: String?
    /// Names of people recognized in frame, from `FaceMemoryService`.
    let people: [String]
    /// Saved place the user is standing in, from `PlaceMemoryService`.
    let place: String?

    /// Build from the vision pipeline's output.
    init(
        aiResponse: AIVisionResponse?,
        skillResult: SkillResult?,
        people: [String] = [],
        place: String? = nil
    ) {
        self.category = aiResponse?.category ?? skillResult?.category.rawValue ?? "unknown"
        self.description = aiResponse?.description ?? ""
        self.title = skillResult?.title
        self.subtitle = skillResult?.subtitle
        self.details = skillResult?.details.map { "\($0.label): \($0.value)" } ?? []
        self.source = skillResult?.sourceApp
        self.people = people
        self.place = place
    }
}

struct ChatRequest: Codable {
    let message: String
    let sessionId: String
    let clientContext: ClientContext?
    let visionContext: VisionContext?
    /// Persona name, so the Worker addresses itself correctly if the user
    /// renamed the assistant.
    let assistantName: String
}

struct ChatResponse: Codable {
    let response: String
    let sessionId: String?
    let action: BrainAction?
}

/// A directive the brain can return instead of (or alongside) prose.
/// Today the only one is `capture`: the brain decided it needs to see something
/// before it can answer. This is the escape hatch for everything `IntentRouter`
/// classifies as chat but that actually needed eyes.
struct BrainAction: Codable, Equatable {
    let type: String
    let reason: String?

    static let capture = "capture"
    var isCapture: Bool { type == BrainAction.capture }
}

/// One server-sent event from `/chat/stream`.
struct StreamChunk: Codable {
    let sentence: String?
    let sentenceIndex: Int?
    let done: Bool?
    let fullResponse: String?
    let sessionId: String?
    let action: BrainAction?
    let error: String?
}

// MARK: - Brain Errors

enum BrainError: LocalizedError {
    case notConfigured
    case unauthorized
    case serverError(statusCode: Int)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No brain configured. Add your Worker URL, or a Claude key to run on-device."
        case .unauthorized:
            return "The brain rejected the token. Check your Worker bearer token in Settings."
        case .serverError(let code):
            return "Brain error (\(code))."
        case .noResponse:
            return "No response from the brain."
        }
    }
}

// MARK: - Brain Service

/// Client for the Cloudflare Worker brain, with a direct-to-Claude fallback so
/// the assistant still works before the Worker is deployed.
///
/// Ported from Jarvis's `JarvisAPI`, with three changes: configuration comes
/// from `SettingsManager` rather than a global `JarvisConfig`; requests carry
/// `VisionContext`; and the fallback path authenticates with the user's actual
/// Claude key rather than reusing the Worker bearer token (which never worked).
final class BrainService {

    private let settings: SettingsManager
    private let session: URLSession

    init(settings: SettingsManager) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: config)
    }

    /// True when *some* path to a language model exists — Worker or direct key.
    var isUsable: Bool {
        settings.isBrainConfigured || !settings.claudeAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Chat

    func send(
        _ message: String,
        sessionId: String,
        context: ClientContext?,
        vision: VisionContext?
    ) async throws -> ChatResponse {
        guard settings.isBrainConfigured else {
            let text = try await sendDirect(message, vision: vision, history: [])
            return ChatResponse(response: text, sessionId: sessionId, action: nil)
        }

        var request = try brainRequest(path: "/chat")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                message: message,
                sessionId: sessionId,
                clientContext: context,
                visionContext: vision,
                assistantName: settings.assistantName
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    /// Streaming chat. `onSentence` fires per complete sentence so TTS can start
    /// speaking before the full response has arrived — the single biggest
    /// perceived-latency win in the whole loop.
    func sendStreaming(
        _ message: String,
        sessionId: String,
        context: ClientContext?,
        vision: VisionContext?,
        onSentence: @escaping (String) -> Void,
        onAction: @escaping (BrainAction) -> Void,
        onComplete: @escaping (String) -> Void
    ) async throws {
        guard settings.isBrainConfigured else {
            let text = try await sendDirect(message, vision: vision, history: [])
            onSentence(text)
            onComplete(text)
            return
        }

        var request = try brainRequest(path: "/chat/stream")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                message: message,
                sessionId: sessionId,
                clientContext: context,
                visionContext: vision,
                assistantName: settings.assistantName
            )
        )

        let (bytes, response) = try await session.bytes(for: request)
        try validate(response)

        var seenIndices = Set<Int>()
        var accumulated = ""
        var sawAnyLine = false

        #if DEBUG
        print("🧠 /chat/stream opened")
        #endif

        for try await line in bytes.lines {
            sawAnyLine = true
            guard line.hasPrefix("data: ") else {
                #if DEBUG
                if !line.isEmpty { print("🧠 non-data line: \(line.prefix(120))") }
                #endif
                continue
            }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }

            if let action = chunk.action {
                onAction(action)
            }

            if let sentence = chunk.sentence, !sentence.isEmpty {
                // The Worker may resend a sentence on retry; index-dedupe so we
                // never speak the same clause twice.
                let index = chunk.sentenceIndex ?? seenIndices.count
                if seenIndices.insert(index).inserted {
                    accumulated += (accumulated.isEmpty ? "" : " ") + sentence
                    onSentence(sentence)
                }
            }

            if let error = chunk.error {
                #if DEBUG
                print("🧠 stream reported error: \(error)")
                #endif
            }

            if chunk.done == true {
                #if DEBUG
                print("🧠 stream done — \(seenIndices.count) sentence(s)")
                #endif
                onComplete(chunk.fullResponse ?? accumulated)
                return
            }
        }

        // Stream ended without an explicit done frame — treat what we got as
        // the full answer rather than dropping it.
        #if DEBUG
        print("🧠 stream closed without done frame (sawAnyLine=\(sawAnyLine), chars=\(accumulated.count))")
        #endif
        onComplete(accumulated)
    }

    func clearSession(_ sessionId: String) async throws {
        guard settings.isBrainConfigured else { return }
        var request = try brainRequest(path: "/session/clear")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        _ = try? await session.data(for: request)
    }

    // MARK: - Calendar

    func checkCalendarStatus() async -> Bool {
        guard settings.isBrainConfigured,
              let url = URL(string: settings.normalizedBrainURL + "/auth/google/status")
        else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.brainAPIToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        return json["connected"] as? Bool ?? false
    }

    func calendarAuthURL() -> URL? {
        guard settings.isBrainConfigured else { return nil }
        return URL(string: settings.normalizedBrainURL + "/auth/google/start")
    }

    /// Cheap liveness probe for the Settings screen.
    func checkHealth() async -> Bool {
        guard settings.isBrainConfigured,
              let url = URL(string: settings.normalizedBrainURL + "/health")
        else { return false }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Direct Claude Fallback

    /// Talk straight to the Claude API when no Worker is deployed. Loses
    /// server-side memory and the weather/calendar injection, but keeps the app
    /// fully functional — which matters because the Worker is optional setup.
    func sendDirect(
        _ message: String,
        vision: VisionContext?,
        history: [ConversationMessage]
    ) async throws -> String {
        let key = settings.claudeAPIKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw BrainError.notConfigured }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        var messages: [[String: String]] = history.suffix(20).map {
            ["role": $0.role.rawValue, "content": $0.text]
        }

        var userMessage = message
        if let vision {
            userMessage = """
            [What I'm looking at right now]
            \(Self.describe(vision))

            \(message)
            """
        }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 512,
            "system": localSystemPrompt(),
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.compactMap { $0["text"] as? String }.joined(separator: "\n")

        guard let text, !text.isEmpty else { throw BrainError.noResponse }
        return text
    }

    /// Flatten a `VisionContext` into the prose the model actually reads.
    static func describe(_ vision: VisionContext) -> String {
        var lines: [String] = []
        if !vision.description.isEmpty { lines.append(vision.description) }
        if let title = vision.title { lines.append("Identified as: \(title)") }
        if let subtitle = vision.subtitle, !subtitle.isEmpty { lines.append(subtitle) }
        lines.append(contentsOf: vision.details)
        if !vision.people.isEmpty {
            lines.append("People in frame: \(vision.people.joined(separator: ", "))")
        }
        if let place = vision.place { lines.append("Current place: \(place)") }
        if let source = vision.source { lines.append("Data source: \(source)") }
        return lines.joined(separator: "\n")
    }

    private func localSystemPrompt() -> String {
        """
        You are \(settings.assistantName), a personal AI assistant with eyes — you can see through \
        the user's phone camera and their Meta Ray-Ban glasses. Composed, dry-witted, efficient. \
        You speak like a brilliant colleague who respects the user too much to waste their time.

        Your replies are spoken aloud, so: no lists, no markdown, no headers. Keep simple answers to \
        one or two sentences. Never open with "Sure!" or "Of course!" — just answer.

        When a "[What I'm looking at right now]" block is present, it came from a real camera frame \
        that was analyzed a moment ago. Treat it as ground truth about the user's surroundings and \
        answer their question about it directly rather than describing the block back to them.
        """
    }

    // MARK: - Plumbing

    private func brainRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: settings.normalizedBrainURL + path) else {
            throw BrainError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.brainAPIToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BrainError.noResponse }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw BrainError.unauthorized
        default: throw BrainError.serverError(statusCode: http.statusCode)
        }
    }

    // MARK: - Context Snapshot

    /// Assemble the per-request client context.
    @MainActor
    static func snapshot(location: String?, glassesConnected: Bool) -> ClientContext {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d 'at' h:mm a"

        return ClientContext(
            location: location,
            batteryLevel: battery < 0 ? nil : Int(battery * 100),
            localTime: formatter.string(from: Date()),
            timeZone: TimeZone.current.identifier,
            glassesConnected: glassesConnected
        )
    }
}
