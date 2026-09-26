// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

public struct PipelineResult: Sendable {
    public let transcript: String
    public let polished: String
    public let summary: String
    public let model: String
    public init(transcript: String, polished: String, summary: String, model: String) {
        self.transcript = transcript
        self.polished = polished
        self.summary = summary
        self.model = model
    }
}

public enum PipelineError: Error, LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case fileNotReady(String)
    case badResponse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key set for \(p). Add one in Settings."
        case .http(let code, let body): return "Request failed (HTTP \(code)): \(body)"
        case .fileNotReady(let s): return "Audio upload didn't become ready: \(s)"
        case .badResponse(let s): return "Unexpected response: \(s)"
        case .unsupported(let s): return s
        }
    }
}

/// How long a single transcription chunk may be before the audio is split.
public let kMeetGistChunkSeconds: Double = 20 * 60

// MARK: - Two-slot pipeline

/// Audio → transcript (master timeline, `[MM:SS] Speaker: …`).
public protocol Transcriber: Sendable {
    var label: String { get }
    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Transcript text → (polished minutes, summary).
public protocol NotesWriter: Sendable {
    var label: String { get }
    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws -> (polished: String, summary: String)
}

/// A complete pipeline = one transcriber + one notes writer (possibly different
/// providers, e.g. Gemini transcription + DeepSeek notes).
public struct ComposedPipeline: MeetingPipeline, Sendable {
    public let providerName: String
    let transcriber: Transcriber
    let notesWriter: NotesWriter

    public func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                           progress: @escaping @Sendable (String) -> Void) async throws
        -> (transcript: String, transcriberLabel: String) {
        let transcript = try await transcriber.transcribe(
            sessionDir: sessionDir, micExists: micExists, systemExists: systemExists, progress: progress)
        return (transcript, transcriber.label)
    }

    public func writeNotes(transcript: String,
                           progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String, notesLabel: String) {
        let (polished, summary) = try await notesWriter.notes(transcript: transcript, progress: progress)
        return (polished, summary, notesWriter.label)
    }
}

/// Two independent stages so a caller can persist the transcript durably
/// between them (see `MeetingProcessor.process`, which writes `transcript.md`
/// right after `transcribe` succeeds and before `writeNotes` ever runs — a
/// notes failure must never discard an already-produced transcript).
/// `ComposedPipeline` is currently the only conformer.
public protocol MeetingPipeline: Sendable {
    var providerName: String { get }
    /// Stage 1: audio → transcript. The label describes only the transcription
    /// provider that ran (e.g. "gemini-flash-latest").
    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws
        -> (transcript: String, transcriberLabel: String)
    /// Stage 2: transcript → (polished, summary). The label describes only the
    /// notes provider that ran.
    func writeNotes(transcript: String,
                    progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String, notesLabel: String)
}

public extension MeetingPipeline {
    /// Convenience wrapper kept for source compatibility with callers that want
    /// the old single-call shape; holds the transcript only in memory, so
    /// prefer driving `transcribe`/`writeNotes` directly when the transcript
    /// must be persisted before notes run (see `MeetingProcessor.process`).
    func process(sessionDir: URL, micExists: Bool, systemExists: Bool,
                 generateNotes: Bool = true,
                 progress: @escaping @Sendable (String) -> Void) async throws -> PipelineResult {
        let (transcript, transcriberLabel) = try await transcribe(
            sessionDir: sessionDir, micExists: micExists, systemExists: systemExists, progress: progress)
        guard generateNotes else {
            return PipelineResult(transcript: transcript, polished: "", summary: "", model: transcriberLabel)
        }
        let (polished, summary, notesLabel) = try await writeNotes(transcript: transcript, progress: progress)
        return PipelineResult(transcript: transcript, polished: polished, summary: summary,
                              model: "\(transcriberLabel) → \(notesLabel)")
    }
}

public enum Pipelines {
    /// Build a pipeline from the selected transcription + notes providers and their
    /// keys. Throws a `PipelineError` describing what's missing/unsupported.
    public static func make(transcription: Provider, transcriptionKey: String?,
                            notes: Provider, notesKey: String?,
                            notesTemplate: String? = nil,
                            notesLanguage: String? = nil) throws -> MeetingPipeline {
        let transcriber: Transcriber
        switch transcription.transcribeStyle {
        case .gemini:
            guard let key = transcriptionKey, !key.isEmpty else { throw PipelineError.missingKey(transcription.name) }
            transcriber = GeminiTranscriber(apiKey: key, baseURL: transcription.baseURL,
                                            model: transcription.transcribeModel ?? "gemini-flash-latest")
        case .whisper:
            guard let key = transcriptionKey, !key.isEmpty else { throw PipelineError.missingKey(transcription.name) }
            transcriber = WhisperTranscriber(apiKey: key, baseURL: transcription.baseURL,
                                             model: transcription.transcribeModel ?? "whisper-1")
        case .offline, nil:
            throw PipelineError.unsupported("\(transcription.name) can't transcribe audio — pick a transcription provider.")
        }

        let writer = try makeNotesWriter(notes: notes, notesKey: notesKey,
                                         notesTemplate: notesTemplate, notesLanguage: notesLanguage)

        return ComposedPipeline(providerName: "\(transcription.name) → \(notes.name)",
                                transcriber: transcriber, notesWriter: writer)
    }

    /// Build only the transcript → minutes stage. Offline transcription uses this
    /// later, without changing the existing composed cloud pipeline.
    public static func makeNotesWriter(notes: Provider, notesKey: String?,
                                       notesTemplate: String? = nil,
                                       notesLanguage: String? = nil) throws -> any NotesWriter {
        let language = (notesLanguage?.isEmpty == false) ? notesLanguage! : Prompts.defaultNotesLanguage
        let writer: NotesWriter
        switch notes.notesStyle {
        case .gemini:
            guard let key = notesKey, !key.isEmpty else { throw PipelineError.missingKey(notes.name) }
            writer = GeminiNotesWriter(apiKey: key, baseURL: notes.baseURL,
                                       model: notes.notesModel ?? "gemini-flash-latest",
                                       template: notesTemplate, language: language)
        case .chat:
            guard let key = notesKey, !key.isEmpty else { throw PipelineError.missingKey(notes.name) }
            guard let model = notes.notesModel, !model.isEmpty else {
                throw PipelineError.unsupported("\(notes.name) needs a model name in Settings.")
            }
            writer = ChatNotesWriter(apiKey: key, baseURL: notes.baseURL, model: model,
                                     template: notesTemplate, language: language)
        case .apple:
            writer = AppleFoundationModelsNotesWriter(template: notesTemplate, language: language)
        case .qwenMLX:
            writer = QwenMLXNotesWriter(template: notesTemplate, language: language)
        case .codexCLI:
            writer = CodexCLINotesWriter(template: notesTemplate, language: language,
                                         reasoningEffort: notes.notesReasoningEffort)
        case nil:
            throw PipelineError.unsupported("\(notes.name) can't write notes.")
        }
        return writer
    }
}

// MARK: - Transcript helpers (shared by transcribers)

public enum TranscriptText {
    /// Add `offset` seconds to each `[MM:SS]`/`[HH:MM:SS]` line (for chunked audio).
    public static func offsetTimestamps(_ transcript: String, by offset: Double) -> String {
        guard offset > 0 else { return transcript }
        let pattern = try! NSRegularExpression(pattern: #"^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]"#)
        var lines: [String] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let m = pattern.firstMatch(in: s, range: range) else { lines.append(s); continue }
            func grp(_ i: Int) -> Int { guard let r = Range(m.range(at: i), in: s) else { return 0 }; return Int(s[r]) ?? 0 }
            let hasH = m.range(at: 3).location != NSNotFound
            let secs: Int = hasH ? grp(1) * 3600 + grp(2) * 60 + grp(3) : grp(1) * 60 + grp(2)
            let total = Double(secs) + offset
            let rest = String(s[Range(m.range, in: s)!.upperBound...])
            lines.append("[\(stamp(total))]\(rest)")
        }
        return lines.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double) -> String {
        let t = max(0, Int(seconds)); let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Sort `[MM:SS] …` lines by timestamp (used when merging tracks/chunks).
    public static func sortByTimestamp(_ lines: [String]) -> [String] {
        func key(_ line: String) -> Double {
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"),
                  open < close else { return .greatestFiniteMagnitude }
            let parts = line[line.index(after: open)..<close].split(separator: ":").compactMap { Int($0) }
            switch parts.count {
            case 2: return Double(parts[0] * 60 + parts[1])
            case 3: return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
            default: return .greatestFiniteMagnitude
            }
        }
        return lines.sorted { key($0) < key($1) }
    }
}
