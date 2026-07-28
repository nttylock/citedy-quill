import Foundation

/// Post-process Whisper output and prepare text for TTS.
enum TranscriptCleanup {
    /// Classic Whisper hallucinations on silence / low-energy system audio
    /// (especially Russian "subtitle editor" credits).
    private static let hallucinationPatterns: [NSRegularExpression] = {
        let raw = [
            #"редактор\s+субтитров"#,
            #"корректор\s+[а-яa-z]\.?"#,
            #"субтитры\s+создав"#,
            #"субтитры\s+сделал"#,
            #"продолжение\s+следует"#,
            #"спасибо\s+за\s+просмотр"#,
            #"подписывайтесь\s+на\s+канал"#,
            #"like\s+and\s+subscribe"#,
            #"thanks\s+for\s+watching"#,
            #"subtitle[sd]?\s+by"#,
            #"amara\.org"#,
        ]
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Drop segments that are pure STT garbage / silence hallucinations.
    static func filterSegments(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        segments.filter { !isHallucination($0.text) }
    }

    static func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Very short non-speech fillers alone
        if t.count <= 2 { return true }
        for re in hallucinationPatterns {
            let range = NSRange(t.startIndex..., in: t)
            if re.firstMatch(in: t, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Strip markdown / labels so TTS does not say "hash hash" / "ИТОГ colon".
    static func forSpeech(_ text: String) -> String {
        var s = text
        // Fenced code
        s = s.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: " ",
            options: .regularExpression
        )
        // Headings: "## Title" → "Title"
        s = s.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        // Bold/italic markers
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "_", with: " ")
        // Bullet / numbered list markers at line start
        s = s.replacingOccurrences(
            of: #"(?m)^\s*[-*+]\s+"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^\s*\d+[.)]\s+"#,
            with: "",
            options: .regularExpression
        )
        // Section labels we inject (don't speak the all-caps headers alone awkwardly)
        let labelMap: [(String, String)] = [
            ("ИТОГ\n", "Итог. "),
            ("КЛЮЧЕВОЕ\n", "Ключевое. "),
            ("ТРАНСКРИПТ\n", ""),
        ]
        for (from, to) in labelMap {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // Speaker/time tags from plain transcript: "[0:14] me:" → ""
        s = s.replacingOccurrences(
            of: #"\[\d{1,2}:\d{2}(?::\d{2})?\]\s*(me|them|speaker\s*\d*)\s*:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n"#, with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\.\s*\."#, with: ".", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
