// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public extension MeetingProcessor {
    /// Run only the optional Meeting Minutes stage from an existing transcript.
    @discardableResult
    static func generateNotes(sessionDir: URL, notesProvider: Provider,
                              notesKey: String?, notesTemplate: String?,
                              notesLanguage: String? = nil,
                              progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        let writer = try Pipelines.makeNotesWriter(notes: notesProvider, notesKey: notesKey,
                                                   notesTemplate: notesTemplate,
                                                   notesLanguage: notesLanguage)
        return try await generateNotes(sessionDir: sessionDir, writer: writer,
                                       providerName: notesProvider.name, progress: progress)
    }

    /// Small test seam around the already-existing NotesWriter protocol. Offline
    /// transcription remains independent; this stage reads only transcript.md.
    @discardableResult
    internal static func generateNotes(sessionDir: URL, writer: any NotesWriter,
                                       providerName: String,
                                       progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        let transcriptURL = sessionDir.appendingPathComponent("transcript.md")
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("transcript.md is empty")
        }
        let result = try await writer.notes(transcript: transcript, progress: progress)
        try (result.polished + "\n").write(
            to: sessionDir.appendingPathComponent("polished.md"), atomically: true, encoding: .utf8)
        try (result.summary + "\n").write(
            to: sessionDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        // This stage can follow either local or cloud transcription, so its
        // metadata describes only the notes provider it actually used.
        let meta: [String: Any] = ["provider": providerName, "model": writer.label]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: sessionDir.appendingPathComponent("postprocess_meta.json"), options: .atomic)
        }
        return result
    }
}
