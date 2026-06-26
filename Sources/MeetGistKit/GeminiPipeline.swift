// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Gemini implementation of `MeetingPipeline` using the REST API directly
/// (URLSession, BYOK). Two calls, mirroring postprocess.py: audio → transcript,
/// then transcript text → polished + summary.
public struct GeminiPipeline: MeetingPipeline, Sendable {
    public static let defaultModel = "gemini-2.5-flash"
    public let providerName = "Gemini"

    private let apiKey: String
    private let model: String
    private let base = "https://generativelanguage.googleapis.com"

    public init(apiKey: String, model: String = defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    public func process(sessionDir: URL,
                        micExists: Bool,
                        systemExists: Bool,
                        progress: @escaping @Sendable (String) -> Void) async throws -> PipelineResult {
        var tracks: [URL] = []
        if micExists { tracks.append(sessionDir.appendingPathComponent("mic.m4a")) }
        if systemExists { tracks.append(sessionDir.appendingPathComponent("system.m4a")) }
        guard !tracks.isEmpty else { throw PipelineError.badResponse("no audio files") }

        // 1. Upload each track and wait for it to become ACTIVE.
        var fileParts: [[String: Any]] = []
        for url in tracks {
            progress("Uploading \(url.lastPathComponent)…")
            let f = try await uploadAndWait(url)
            fileParts.append(["fileData": ["mimeType": f.mime, "fileUri": f.uri]])
        }

        // 2. Audio → transcript.
        progress("Transcribing…")
        let tPrompt = Prompts.transcript(micExists: micExists, systemExists: systemExists)
        let tRaw = try await generate(parts: [["text": tPrompt]] + fileParts)
        let transcript = section(after: "---TRANSCRIPT---", in: tRaw)

        // 3. Transcript → polished + summary.
        progress("Writing minutes & summary…")
        let pRaw = try await generate(parts: [["text": Prompts.polished], ["text": transcript]])
        let (polished, summary) = splitPolished(pRaw)

        return PipelineResult(transcript: transcript, polished: polished,
                              summary: summary, model: model)
    }

    // MARK: - HTTP

    private struct FileInfo: Decodable {
        let name: String?
        let uri: String?
        let state: String?
        let mimeType: String?
    }
    private struct FileWrap: Decodable { let file: FileInfo }
    private struct GenResponse: Decodable {
        struct Candidate: Decodable {
            struct ContentR: Decodable { struct PartR: Decodable { let text: String? }; let parts: [PartR]? }
            let content: ContentR?
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }

    private func uploadAndWait(_ url: URL) async throws -> (uri: String, mime: String) {
        let data = try Data(contentsOf: url)
        let mime = AudioTools.mimeType(for: url)

        // Start resumable upload.
        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(apiKey)")!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": url.lastPathComponent]])
        let (_, sResp) = try await URLSession.shared.data(for: start)
        guard let http = sResp as? HTTPURLResponse,
              let uploadURL = http.value(forHTTPHeaderField: "X-Goog-Upload-URL")
        else { throw PipelineError.badResponse("no upload URL") }

        // Upload bytes + finalize.
        var up = URLRequest(url: URL(string: uploadURL)!)
        up.httpMethod = "POST"
        up.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        up.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        up.httpBody = data
        let (uData, uResp) = try await URLSession.shared.data(for: up)
        try ensureOK(uResp, uData)
        var info = try JSONDecoder().decode(FileWrap.self, from: uData).file

        // Poll until ACTIVE.
        var waited = 0
        while (info.state ?? "") == "PROCESSING", waited < 120 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
            guard let name = info.name else { break }
            var get = URLRequest(url: URL(string: "\(base)/v1beta/\(name)?key=\(apiKey)")!)
            get.httpMethod = "GET"
            let (gData, gResp) = try await URLSession.shared.data(for: get)
            try ensureOK(gResp, gData)
            info = try JSONDecoder().decode(FileInfo.self, from: gData)
        }
        guard info.state == "ACTIVE", let uri = info.uri else {
            throw PipelineError.fileNotReady(info.state ?? "unknown")
        }
        return (uri, info.mimeType ?? mime)
    }

    private func generate(parts: [[String: Any]]) async throws -> String {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["temperature": 0.2],
        ]
        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data)
        let decoded = try JSONDecoder().decode(GenResponse.self, from: data)
        let text = decoded.candidates?.first?.content?.parts?
            .compactMap { $0.text }.joined() ?? ""
        if text.isEmpty { throw PipelineError.badResponse("empty model output") }
        return text
    }

    private func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.http(http.statusCode, String(body.prefix(400)))
        }
    }

    // MARK: - Parsing

    private func section(after marker: String, in text: String) -> String {
        guard let r = text.range(of: marker) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitPolished(_ text: String) -> (polished: String, summary: String) {
        let body = section(after: "---POLISHED---", in: text)
        if let r = body.range(of: "---SUMMARY---") {
            let polished = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (polished, summary)
        }
        return (body, "")
    }
}
