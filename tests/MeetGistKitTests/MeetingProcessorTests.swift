// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

private struct TranscriptEchoWriter: NotesWriter {
    let label = "Test notes"
    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        progress("Writing test notes")
        return ("polished: \(transcript)", "summary: \(transcript)")
    }
}

private struct FixedTranscriber: Transcriber {
    let text: String
    let label = "Test transcriber"
    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws -> String {
        progress("Transcribing…")
        return text
    }
}

private struct BoomError: Error, LocalizedError {
    var errorDescription: String? { "notes writer exploded" }
}

private struct ThrowingNotesWriter: NotesWriter {
    let label = "Test notes"
    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        throw BoomError()
    }
}

@Suite struct MeetingProcessorTests {
    /// P0-1 regression: a notes-stage failure must not discard an
    /// already-produced transcript. `ComposedPipeline` transcribes first;
    /// `MeetingProcessor.process` must persist transcript.md right after that
    /// succeeds and before the (possibly failing) notes stage ever runs.
    @Test func cloudPipelinePersistsTranscriptWhenNotesWriterThrows() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-pipeline")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("mic.m4a"))

        let transcriptText = "[00:01] Speaker: paid-for transcript"
        let pipeline = ComposedPipeline(providerName: "Test → Test",
                                        transcriber: FixedTranscriber(text: transcriptText),
                                        notesWriter: ThrowingNotesWriter())

        await #expect(throws: BoomError.self) {
            _ = try await MeetingProcessor.process(sessionDir: root, pipeline: pipeline) { _ in }
        }

        #expect(try String(contentsOf: root.appendingPathComponent("transcript.md"))
            .contains(transcriptText))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("postprocess_meta.json").path))
    }

    @Test func generateMinutesConsumesExistingOfflineTranscript() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-notes")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcript = "[00:01] Speaker: Benchmark decision"
        try transcript.write(to: root.appendingPathComponent("transcript.md"),
                             atomically: true, encoding: .utf8)

        let result = try await MeetingProcessor.generateNotes(
            sessionDir: root, writer: TranscriptEchoWriter(), providerName: "Test provider",
            progress: { _ in })

        #expect(result.polished == "polished: \(transcript)")
        #expect(result.summary == "summary: \(transcript)")
        #expect(try String(contentsOf: root.appendingPathComponent("polished.md"))
            .contains(transcript))
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("postprocess_meta.json"))) as? [String: String]
        #expect(metadata?["provider"] == "Test provider")
        #expect(metadata?["model"] == "Test notes")
        #expect(metadata?["transcription"] == nil)
    }
}
