import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        /// Transcription finished successfully — UI should show the text.
        case completed(session: String, sessionDir: URL, plainText: String, markdown: String)
        case failed(session: String, message: String)
    }

    enum TranscribeError: Error, CustomStringConvertible {
        case allTracksFailed(session: String)

        var description: String {
            switch self {
            case .allTracksFailed(let s):
                return "all tracks failed for \(s) — not writing empty transcript"
            }
        }
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let name = dir.lastPathComponent
            publish(.transcribing(session: name, queued: queue.count))
            do {
                let result = try await transcribe(dir)
                publish(.completed(
                    session: name,
                    sessionDir: dir,
                    plainText: result.plainText,
                    markdown: result.markdown
                ))
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = name
                publish(.failed(session: name, message: "\(error)"))
            }
        }
        await engine?.release()
        engine = nil
        // Stay on last completed/failed UI state — only go idle if nothing failed
        // and queue is empty without a final result. Handlers treat idle as "clear menu".
        if lastFailure == nil {
            publish(.idle)
        }
        draining = false
        drainIfIdle()
    }

    private struct TranscribeResult {
        let plainText: String
        let markdown: String
    }

    private func transcribe(_ dir: URL) async throws -> TranscribeResult {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var trackErrors = 0
        var tracksAttempted = 0
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            tracksAttempted += 1
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                trackErrors += 1
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let beforeFilter = merged.count
        merged = TranscriptCleanup.filterSegments(merged)
        let dropped = beforeFilter - merged.count
        if dropped > 0 {
            log(dir, "dropped \(dropped) hallucinated segment(s) (subtitle-credits / silence junk)")
        }

        // Don't write an empty "success" transcript when every track failed —
        // resumePending uses presence of transcript.json as "done".
        if tracksAttempted > 0, trackErrors == tracksAttempted, merged.isEmpty {
            throw TranscribeError.allTracksFailed(session: dir.lastPathComponent)
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
        return TranscribeResult(
            plainText: transcript.plainText(),
            markdown: transcript.rendered(title: dir.lastPathComponent)
        )
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine().lowercased()
        let engine: TranscriptionEngine
        switch configured {
        case "openai", "whisper", "parakeet":
            // parakeet is not linked in this build (breaks menu-bar status item
            // when co-loaded). Always use OpenAI; warn if config asked for parakeet.
            if configured == "parakeet" {
                FileHandle.standardError.write(Data(
                    "warning: parakeet not available in this build — using openai\n".utf8
                ))
            }
            guard let apiKey = Config.openAIAPIKey() else {
                throw OpenAIEngineError.missingAPIKey
            }
            engine = OpenAIEngine(
                apiKey: apiKey,
                model: Config.transcriptionModel(),
                language: Config.transcriptionLanguage(),
                baseURL: Config.transcriptionBaseURL()
            )
        default:
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using openai\n".utf8
            ))
            guard let apiKey = Config.openAIAPIKey() else {
                throw OpenAIEngineError.missingAPIKey
            }
            engine = OpenAIEngine(
                apiKey: apiKey,
                model: Config.transcriptionModel(),
                language: Config.transcriptionLanguage(),
                baseURL: Config.transcriptionBaseURL()
            )
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. (`TranscriptCleanup` filters segment text.)
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable plain text for the result window / clipboard / email.
    func plainText() -> String {
        segments.map { seg in
            "[\(Self.clock(seg.start_ms))] \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
