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
        let langHint = languageHint(language)

        let system = """
        You are a meeting-notes assistant. \(langHint)
        Given a speaker-tagged transcript, extract the essentials.
        Return ONLY valid JSON with keys:
          - "summary": 2-5 sentences covering the main outcome
          - "key_points": array of 3-8 short bullet strings (decisions, action items, facts)
        Ignore filler, greetings, and speech-to-text noise. Be concrete.
        IMPORTANT: Completely ignore lines about «Редактор субтитров», «Корректор»,
        subtitle credits, "продолжение следует", or similar Whisper silence hallucinations.
        Never invent participants from those credits.
        """

        let content = try await chatJSON(
            system: system,
            user: transcript,
            apiKey: apiKey,
            baseURL: baseURL,
            temperature: 0.2
        )
        return try parseSummaryContent(content)
    }

    /// Formal meeting protocol: decisions, action items, open questions.
    static func generateProtocol(
        transcript: String,
        language: String?,
        apiKey: String,
        baseURL: URL
    ) async throws -> String {
        let langHint = languageHint(language)
        let system = """
        You are an executive assistant writing a formal meeting protocol. \(langHint)
        From the speaker-tagged transcript produce a clean protocol in markdown with sections:
        ## Участники (if inferable, else skip)
        ## Повестка / темы
        ## Решения
        ## Action items (who / what / when if known)
        ## Открытые вопросы
        ## Краткий итог (2-3 sentences)
        Be factual. No filler. If something is unclear, say so briefly.
        CRITICAL: Ignore «Редактор субтитров», «Корректор А.…», subtitle/credit lines —
        they are speech-to-text hallucinations on silence, NOT real participants.
        Do not list them under Участники.
        Return ONLY the markdown protocol, no JSON wrapper.
        """
        return try await chatText(
            system: system,
            user: transcript,
            apiKey: apiKey,
            baseURL: baseURL,
            temperature: 0.2
        )
    }

    // MARK: - OpenAI chat helpers

    private static func languageHint(_ language: String?) -> String {
        (language == "ru" || language?.hasPrefix("ru") == true)
            ? "Отвечай на русском языке."
            : "Reply in the same language as the transcript."
    }

    private static func chatJSON(
        system: String,
        user: String,
        apiKey: String,
        baseURL: URL,
        temperature: Double
    ) async throws -> String {
        try await chat(
            system: system,
            user: user,
            apiKey: apiKey,
            baseURL: baseURL,
            temperature: temperature,
            jsonObject: true
        )
    }

    private static func chatText(
        system: String,
        user: String,
        apiKey: String,
        baseURL: URL,
        temperature: Double
    ) async throws -> String {
        try await chat(
            system: system,
            user: user,
            apiKey: apiKey,
            baseURL: baseURL,
            temperature: temperature,
            jsonObject: false
        )
    }

    private static func chat(
        system: String,
        user: String,
        apiKey: String,
        baseURL: URL,
        temperature: Double,
        jsonObject: Bool
    ) async throws -> String {
        let userText = user.isEmpty
            ? "(empty transcript)"
            : String(user.prefix(100_000))

        var body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userText],
            ],
        ]
        if jsonObject {
            body["response_format"] = ["type": "json_object"]
        }

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
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSummaryContent(_ content: String) throws -> TranscriptSummary {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
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
