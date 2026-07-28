import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",          // or "openai"
///         "model": "whisper-1",          // openai only
///         "language": "ru",              // openai only; omit for auto-detect
///         "api_key_env": "OPENAI_API_KEY"
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    /// Optional dotenv-style secrets: ~/.config/quill/env
    static let envPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/env")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. This build supports "openai" (default).
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "openai"
    }

    /// OpenAI model id. Default whisper-1 (reliable verbose_json segments).
    static func transcriptionModel() -> String {
        transcription()?["model"] as? String ?? "whisper-1"
    }

    /// BCP-47 / ISO-639-1 language hint for OpenAI (e.g. "ru"). Nil = auto.
    static func transcriptionLanguage() -> String? {
        guard let lang = transcription()?["language"] as? String, !lang.isEmpty else { return nil }
        return lang
    }

    /// Env var name holding the OpenAI API key. Default OPENAI_API_KEY.
    static func transcriptionAPIKeyEnv() -> String {
        transcription()?["api_key_env"] as? String ?? "OPENAI_API_KEY"
    }

    /// Optional OpenAI base URL override (Azure / proxy). Default api.openai.com/v1.
    static func transcriptionBaseURL() -> URL {
        if let raw = transcription()?["base_url"] as? String, !raw.isEmpty,
           let url = URL(string: raw)
        {
            return url
        }
        return URL(string: "https://api.openai.com/v1")!
    }

    /// Resolve OpenAI API key without printing it.
    /// Order: ~/.config/quill/env → process env → config `api_key`.
    /// File wins over process env so a stale/exported shell key cannot
    /// silently override the key intentionally placed for quill.
    static func openAIAPIKey() -> String? {
        let envName = transcriptionAPIKeyEnv()
        if let fromFile = loadDotEnv(envPath)[envName], !fromFile.isEmpty {
            return fromFile
        }
        if let v = ProcessInfo.processInfo.environment[envName], !v.isEmpty {
            return v
        }
        if let inline = transcription()?["api_key"] as? String, !inline.isEmpty {
            return inline
        }
        return nil
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Minimal KEY=VALUE parser for ~/.config/quill/env.
    private static func loadDotEnv(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\""))
                || (val.hasPrefix("'") && val.hasSuffix("'"))
            {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
