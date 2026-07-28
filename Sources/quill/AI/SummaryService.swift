import Foundation

/// GPT-4o-mini post-process: short summary + bullet key points.
struct TranscriptSummary: Sendable {
    let summary: String
    let keyPoints: [String]
}

enum SummaryServiceError: Error, CustomStringConvertible {
    case missingAPIKey
    case http(Int, String)
    case badResponse(String)

    var description: String {
        switch self {
        case .missingAPIKey: return "OpenAI API key missing"
        case .http(let code, let body): return "OpenAI HTTP \(code): \(body)"
        case .badResponse(let msg): return "summary parse: \(msg)"
        }
    }
}

enum SummaryService {
    static func summarize(
        transcript: String,
        language: String?,
        apiKey: String,
        baseURL: URL
    ) async throws -> TranscriptSummary {
        let langHint = (language == "ru" || language?.hasPrefix("ru") == true)
            ? "Отвечай на русском языке."
            : "Reply in the same language as the transcript."

        let system = """
        You are a meeting-notes assistant. \(langHint)
        Given a speaker-tagged transcript, extract the essentials.
        Return ONLY valid JSON with keys:
          - "summary": 2-5 sentences covering the main outcome
          - "key_points": array of 3-8 short bullet strings (decisions, action items, facts)
        Ignore filler, greetings, and speech-to-text noise. Be concrete.
        """

        let user = transcript.isEmpty
            ? "(empty transcript)"
            : String(transcript.prefix(100_000))

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]

        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryServiceError.badResponse("non-HTTP")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw SummaryServiceError.http(http.statusCode, String(text.prefix(400)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SummaryServiceError.badResponse("missing choices.message.content")
        }

        return try parseContent(content)
    }

    private static func parseContent(_ content: String) throws -> TranscriptSummary {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip accidental ```json fences
        var jsonText = trimmed
        if jsonText.hasPrefix("```") {
            jsonText = jsonText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            let data = jsonText.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SummaryServiceError.badResponse("not JSON")
        }
        let summary = (obj["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var points: [String] = []
        if let arr = obj["key_points"] as? [String] {
            points = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let arr = obj["keyPoints"] as? [String] {
            points = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if summary.isEmpty, points.isEmpty {
            throw SummaryServiceError.badResponse("empty summary")
        }
        return TranscriptSummary(summary: summary, keyPoints: points)
    }
}
