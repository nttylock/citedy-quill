import AVFoundation
import Foundation

enum OpenAIEngineError: Error, CustomStringConvertible {
    case missingAPIKey
    case unreadableAudio(URL, Error?)
    case convertFailed(String)
    case http(Int, String)
    case badResponse(String)

    var description: String {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key not found — set OPENAI_API_KEY or ~/.config/quill/env"
        case .unreadableAudio(let url, let e):
            return "unreadable or empty audio \(url.lastPathComponent)"
                + (e.map { ": \($0)" } ?? "")
        case .convertFailed(let msg):
            return "audio convert failed: \(msg)"
        case .http(let code, let body):
            return "OpenAI HTTP \(code): \(body)"
        case .badResponse(let msg):
            return "OpenAI response: \(msg)"
        }
    }
}

/// Cloud transcription via OpenAI Audio Transcriptions API (whisper-1 by
/// default). Supports Russian and 50+ languages; audio is uploaded to OpenAI
/// (not fully local).
///
/// Requires an API key from (first match wins):
///   1. env var named by config `transcription.api_key_env` (default OPENAI_API_KEY)
///   2. `~/.config/quill/env` line `OPENAI_API_KEY=...`
///   3. config `transcription.api_key` (discouraged — plain text)
actor OpenAIEngine: TranscriptionEngine {
    nonisolated let name = "openai"
    nonisolated let model: String

    private let apiKey: String
    private let language: String?
    private let baseURL: URL
    private var workDir: URL?

    init(apiKey: String, model: String, language: String?, baseURL: URL) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.baseURL = baseURL
    }

    func prepare() async throws {
        if workDir == nil {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-openai-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            workDir = dir
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw OpenAIEngineError.unreadableAudio(audio, nil) }
        } catch let error as OpenAIEngineError {
            throw error
        } catch {
            throw OpenAIEngineError.unreadableAudio(audio, error)
        }

        let upload = try await convertForUpload(audio)
        defer { try? FileManager.default.removeItem(at: upload) }

        let attrs = try FileManager.default.attributesOfItem(atPath: upload.path)
        let size = attrs[.size] as? NSNumber ?? 0
        if size.intValue > 24 * 1024 * 1024 {
            throw OpenAIEngineError.convertFailed(
                "\(upload.lastPathComponent) is \(size.intValue / (1024 * 1024)) MB — OpenAI limit is 25 MB"
            )
        }

        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!
            )
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", model)
        appendField("response_format", "verbose_json")
        appendField("timestamp_granularities[]", "segment")
        if let language, !language.isEmpty {
            appendField("language", language)
        }

        let filename = upload.lastPathComponent
        let fileData = try Data(contentsOf: upload)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEngineError.badResponse("non-HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenAIEngineError.http(http.statusCode, String(text.prefix(500)))
        }

        return try Self.parseVerboseJSON(data)
    }

    func release() async {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
            self.workDir = nil
        }
    }

    private func convertForUpload(_ audio: URL) async throws -> URL {
        let dir = try ensureWorkDir()
        let out = dir.appendingPathComponent(
            audio.deletingPathExtension().lastPathComponent + "-\(UUID().uuidString).m4a"
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        proc.arguments = [
            audio.path,
            out.path,
            "-d", "aac",
            "-f", "m4af",
            "-b", "64000",
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
            return out
        }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? "afconvert exit \(proc.terminationStatus)"
        throw OpenAIEngineError.convertFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func ensureWorkDir() throws -> URL {
        if let workDir { return workDir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-openai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        return dir
    }

    private static func parseVerboseJSON(_ data: Data) throws -> [TranscriptSegment] {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OpenAIEngineError.badResponse("not JSON") }

        if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
            return segments.compactMap { seg in
                guard let text = seg["text"] as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let start = (seg["start"] as? Double)
                    ?? (seg["start"] as? NSNumber)?.doubleValue
                    ?? 0
                let end = (seg["end"] as? Double)
                    ?? (seg["end"] as? NSNumber)?.doubleValue
                    ?? start
                return TranscriptSegment(start: start, end: end, text: trimmed)
            }
        }

        if let text = json["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [] }
            let duration = (json["duration"] as? Double)
                ?? (json["duration"] as? NSNumber)?.doubleValue
                ?? 0
            return [TranscriptSegment(start: 0, end: duration, text: trimmed)]
        }
        throw OpenAIEngineError.badResponse("missing segments/text")
    }
}
