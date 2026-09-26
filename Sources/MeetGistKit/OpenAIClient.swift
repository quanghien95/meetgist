// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// OpenAI-compatible REST helper (works for OpenAI, Groq, DeepSeek, Moonshot, xAI,
/// and any custom base URL). BYOK via Bearer token.
struct OpenAIHTTP: Sendable {
    let apiKey: String
    let base: String   // e.g. https://api.openai.com/v1

    private func authed(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: STT (/audio/transcriptions)

    struct Verbose: Decodable {
        let text: String?
        let segments: [Seg]?
        struct Seg: Decodable { let start: Double?; let text: String? }
    }

    func transcribeFile(_ url: URL, model: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> Verbose {
        let boundary = "meetgist.\(UUID().uuidString)"
        var req = authed("/audio/transcriptions")
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.multipart(
            boundary: boundary,
            fields: ["model": model, "response_format": "verbose_json"],
            fileField: "file", fileURL: url, mime: AudioTools.mimeType(for: url))
        let requestToSend = req
        let data = try await HTTPRetry.withRetry(label: model, policy: .modelCall, progress: progress) { () -> Data in
            let (d, resp) = try await URLSession.shared.data(for: requestToSend)
            try HTTPRetry.ensureOK(resp, d)
            return d
        }
        // Some providers return plain text for verbose_json on small clips; fall back.
        if let v = try? JSONDecoder().decode(Verbose.self, from: data) { return v }
        return Verbose(text: String(data: data, encoding: .utf8), segments: nil)
    }

    // MARK: Chat (/chat/completions)

    private struct ChatResp: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg? }
        let choices: [Choice]?
    }

    func chat(model: String, system: String, user: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var req = authed("/chat/completions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])
        let requestToSend = req
        let decoded = try await HTTPRetry.withRetry(label: model, policy: .modelCall, progress: progress) { () -> ChatResp in
            let (d, resp) = try await URLSession.shared.data(for: requestToSend)
            try HTTPRetry.ensureOK(resp, d)
            return try JSONDecoder().decode(ChatResp.self, from: d)
        }
        let text = decoded.choices?.first?.message?.content ?? ""
        if text.isEmpty { throw PipelineError.badResponse("empty chat output") }
        return text
    }

    static func multipart(boundary: String, fields: [String: String],
                          fileField: String, fileURL: URL, mime: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

/// Whisper-style transcription. Each track is transcribed separately (mic → "Me",
/// system → "Speaker") and merged on the timeline. Long tracks are chunked.
struct WhisperTranscriber: Transcriber {
    let apiKey: String
    let baseURL: String
    let model: String
    var label: String { model }

    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let http = OpenAIHTTP(apiKey: apiKey, base: baseURL)
        var tracks: [(speaker: String, url: URL)] = []
        if micExists { tracks.append(("Me", sessionDir.appendingPathComponent("mic.m4a"))) }
        if systemExists { tracks.append((micExists ? "Speaker" : "Speaker 1",
                                         sessionDir.appendingPathComponent("system.m4a"))) }
        guard !tracks.isEmpty else { throw PipelineError.badResponse("no audio") }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        var lines: [String] = []
        for t in tracks {
            progress("Transcribing \(t.speaker)…")
            let chunks = try await AudioTools.chunk(
                t.url, chunkSeconds: kMeetGistChunkSeconds,
                workDir: work.appendingPathComponent(t.speaker))
            for c in chunks {
                let v = try await http.transcribeFile(c.url, model: model, progress: progress)
                if let segs = v.segments, !segs.isEmpty {
                    for s in segs {
                        let text = (s.text ?? "").trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        let start = (s.start ?? 0) + c.offsetSeconds
                        lines.append("[\(TranscriptText.stamp(start))] \(t.speaker): \(text)")
                    }
                } else if let whole = v.text?.trimmingCharacters(in: .whitespacesAndNewlines), !whole.isEmpty {
                    lines.append("[\(TranscriptText.stamp(c.offsetSeconds))] \(t.speaker): \(whole)")
                }
            }
        }
        return TranscriptText.sortByTimestamp(lines).joined(separator: "\n")
    }
}

/// OpenAI-compatible chat notes writer (OpenAI, DeepSeek, Moonshot, Groq, xAI, custom).
struct ChatNotesWriter: NotesWriter {
    let apiKey: String
    let baseURL: String
    let model: String
    var template: String? = nil
    var language: String = Prompts.defaultNotesLanguage
    var label: String { model }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws -> (polished: String, summary: String) {
        progress("Writing minutes & summary…")
        let http = OpenAIHTTP(apiKey: apiKey, base: baseURL)
        if let t = template, !t.isEmpty {
            let out = try await http.chat(model: model, system: Prompts.templatedNotes(t, language: language), user: transcript, progress: progress)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (out, out)
        }
        let raw = try await http.chat(model: model, system: Prompts.polished(language: language), user: transcript, progress: progress)
        return splitPolished(raw)
    }
}
