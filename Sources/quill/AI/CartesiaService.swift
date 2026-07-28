import Foundation

enum CartesiaServiceError: Error, CustomStringConvertible {
    case missingAPIKey
    case http(Int, String)
    case emptyAudio

    var description: String {
        switch self {
        case .missingAPIKey: return "CARTESIA_API_KEY missing — add to ~/.config/quill/env"
        case .http(let code, let body): return "Cartesia HTTP \(code): \(body)"
        case .emptyAudio: return "Cartesia returned empty audio"
        }
    }
}

/// Cartesia Sonic TTS → MP3 bytes (same shape as Citedy lib/tts/service.ts).
enum CartesiaService {
    /// Max chars per request (Citedy chunks at 900).
    private static let chunkSize = 900

    static func synthesizeMP3(
        text: String,
        language: String?,
        apiKey: String,
        voiceId: String,
        modelId: String
    ) async throws -> Data {
        // Defense in depth: never send markdown markers to TTS.
        let cleaned = TranscriptCleanup.forSpeech(text)
        guard !cleaned.isEmpty else { throw CartesiaServiceError.emptyAudio }

        let lang = cartesiaLanguage(language)
        let chunks = chunk(cleaned, max: chunkSize)
        var parts: [Data] = []
        parts.reserveCapacity(chunks.count)

        for chunk in chunks {
            let body: [String: Any] = [
                "model_id": modelId,
                "transcript": chunk,
                "voice": ["mode": "id", "id": voiceId],
                "language": lang,
                "output_format": [
                    "container": "mp3",
                    "encoding": "mp3",
                    "sample_rate": 44100,
                    "bit_rate": 128_000,
                ],
            ]

            var request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("2025-04-16", forHTTPHeaderField: "Cartesia-Version")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CartesiaServiceError.http(-1, "non-HTTP")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? "<binary>"
                throw CartesiaServiceError.http(http.statusCode, String(text.prefix(400)))
            }
            guard !data.isEmpty else { throw CartesiaServiceError.emptyAudio }
            parts.append(data)
        }

        // Simple concat works for sequential MP3 frames for short clips.
        if parts.count == 1 { return parts[0] }
        var merged = Data()
        for p in parts { merged.append(p) }
        return merged
    }

    private static func cartesiaLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "en" }
        let lower = language.lowercased()
        if lower.hasPrefix("ru") { return "ru" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("de") { return "de" }
        if lower.hasPrefix("fr") { return "fr" }
        if lower.hasPrefix("es") { return "es" }
        if lower.hasPrefix("pt") { return "pt" }
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return String(lower.prefix(2))
    }

    private static func chunk(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let next = current.isEmpty ? String(word) : current + " " + word
            if next.count > max, !current.isEmpty {
                out.append(current)
                current = String(word)
            } else {
                current = next
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
