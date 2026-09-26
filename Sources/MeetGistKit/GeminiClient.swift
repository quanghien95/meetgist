// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Shared Gemini REST helper (Files API upload + generateContent). BYOK.
struct GeminiHTTP: Sendable {
    let apiKey: String
    let base: String   // e.g. https://generativelanguage.googleapis.com

    struct FileInfo: Decodable { let name: String?; let uri: String?; let state: String?; let mimeType: String? }
    private struct FileWrap: Decodable { let file: FileInfo }
    private struct GenResponse: Decodable {
        struct Candidate: Decodable {
            struct ContentR: Decodable { struct PartR: Decodable { let text: String? }; let parts: [PartR]? }
            let content: ContentR?
        }
        let candidates: [Candidate]?
    }

    /// A request against `base` authenticated via the `x-goog-api-key` header
    /// (not a `?key=` query parameter, which is more likely to end up in logs,
    /// proxies, or crash reports). See P2-1.
    func authed(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(base)\(path)")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return req
    }

    func upload(_ url: URL) async throws -> (uri: String, mime: String) {
        let data = try Data(contentsOf: url)
        let mime = AudioTools.mimeType(for: url)
        var start = authed("/upload/v1beta/files")
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": url.lastPathComponent]])
        let (_, sResp) = try await URLSession.shared.data(for: start)
        guard let http = sResp as? HTTPURLResponse,
              let uploadURL = http.value(forHTTPHeaderField: "X-Goog-Upload-URL")
        else { throw PipelineError.badResponse("no upload URL from Gemini") }

        // The upload URL Google returns is itself pre-authenticated (a
        // one-time resumable-session URL) — it never carried our API key
        // either way, so there is nothing to move off it here.
        var up = URLRequest(url: URL(string: uploadURL)!)
        up.httpMethod = "POST"
        up.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        up.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        up.httpBody = data
        let (uData, uResp) = try await URLSession.shared.data(for: up)
        try ensureOK(uResp, uData)
        var info = try JSONDecoder().decode(FileWrap.self, from: uData).file

        var waited = 0
        while (info.state ?? "") == "PROCESSING", waited < 180 {
            try await Task.sleep(nanoseconds: 1_000_000_000); waited += 1
            guard let name = info.name else { break }
            let (gData, gResp) = try await URLSession.shared.data(for: authed("/v1beta/\(name)"))
            try ensureOK(gResp, gData)
            info = try JSONDecoder().decode(FileInfo.self, from: gData)
        }
        guard info.state == "ACTIVE", let uri = info.uri else { throw PipelineError.fileNotReady(info.state ?? "?") }
        return (uri, info.mimeType ?? mime)
    }

    func generate(model: String, parts: [[String: Any]]) async throws -> String {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["temperature": 0.2],
        ]
        var req = authed("/v1beta/models/\(model):generateContent")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data)
        let decoded = try JSONDecoder().decode(GenResponse.self, from: data)
        let text = decoded.candidates?.first?.content?.parts?.compactMap { $0.text }.joined() ?? ""
        if text.isEmpty { throw PipelineError.badResponse("empty Gemini output") }
        return text
    }

    private func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw PipelineError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(400)))
        }
    }
}

/// Gemini transcription: uploads the audio track(s) and asks the model to produce
/// a diarized transcript. Long meetings are chunked.
struct GeminiTranscriber: Transcriber {
    let apiKey: String
    let baseURL: String
    let model: String
    var label: String { model }

    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let http = GeminiHTTP(apiKey: apiKey, base: baseURL)
        var tracks: [(label: String, url: URL)] = []
        if micExists { tracks.append(("mic", sessionDir.appendingPathComponent("mic.m4a"))) }
        if systemExists { tracks.append(("system", sessionDir.appendingPathComponent("system.m4a"))) }
        guard !tracks.isEmpty else { throw PipelineError.badResponse("no audio") }

        let maxDur = await tracks.asyncMaxDuration()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        // Chunk each track into aligned windows (single window if short enough).
        var perTrack: [[AudioTools.Chunk]] = []
        for t in tracks {
            perTrack.append(try await AudioTools.chunk(
                t.url, chunkSeconds: kMeetGistChunkSeconds,
                workDir: work.appendingPathComponent(t.label)))
        }
        let windows = perTrack.map(\.count).max() ?? 1
        let chunked = (maxDur ?? 0) > kMeetGistChunkSeconds && windows > 1

        var parts: [String] = []
        for i in 0..<windows {
            if windows > 1 { progress("Transcribing part \(i + 1)/\(windows)…") } else { progress("Transcribing…") }
            let offset = Double(i) * kMeetGistChunkSeconds
            var fileParts: [[String: Any]] = []
            for chunks in perTrack where i < chunks.count {
                let f = try await http.upload(chunks[i].url)
                fileParts.append(["fileData": ["mimeType": f.mime, "fileUri": f.uri]])
            }
            let prompt = Prompts.transcript(micExists: micExists, systemExists: systemExists,
                                            segmentOffsetSeconds: chunked ? offset : nil)
            let raw = try await http.generate(model: model, parts: [["text": prompt]] + fileParts)
            var seg = section(after: "---TRANSCRIPT---", in: raw)
            if chunked { seg = TranscriptText.offsetTimestamps(seg, by: offset) }
            parts.append(seg)
        }
        return parts.joined(separator: "\n")
    }

    private func section(after marker: String, in text: String) -> String {
        guard let r = text.range(of: marker) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Gemini notes: transcript text → polished + summary (generateContent, text-only).
struct GeminiNotesWriter: NotesWriter {
    let apiKey: String
    let baseURL: String
    let model: String
    var template: String? = nil
    var language: String = Prompts.defaultNotesLanguage
    var label: String { model }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws -> (polished: String, summary: String) {
        progress("Writing minutes & summary…")
        let http = GeminiHTTP(apiKey: apiKey, base: baseURL)
        if let t = template, !t.isEmpty {
            let out = try await http.generate(model: model, parts: [["text": Prompts.templatedNotes(t, language: language)], ["text": transcript]])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (out, out)
        }
        let raw = try await http.generate(model: model, parts: [["text": Prompts.polished(language: language)], ["text": transcript]])
        return splitPolished(raw)
    }
}

func splitPolished(_ text: String) -> (polished: String, summary: String) {
    func after(_ m: String, _ s: String) -> String {
        guard let r = s.range(of: m) else { return s }
        return String(s[r.upperBound...])
    }
    let body = after("---POLISHED---", text)
    if let r = body.range(of: "---SUMMARY---") {
        return (String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return (body.trimmingCharacters(in: .whitespacesAndNewlines), "")
}

extension Array where Element == (label: String, url: URL) {
    func asyncMaxDuration() async -> Double? {
        var m: Double? = nil
        for t in self { if let d = await AudioTools.duration(of: t.url) { m = Swift.max(m ?? 0, d) } }
        return m
    }
}
