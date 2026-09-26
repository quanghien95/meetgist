// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import MeetGistKit
@testable import MeetGistApp

/// Covers `AppState`'s processing lifecycle: `processTask`, the
/// `processGeneration` token every completion path checks before touching
/// `state`/`status`/`lastError`, and the transcript-survives-a-notes-failure
/// contract. Every test builds its own isolated `AppState`
/// (`AppStateTestSupport.makeAppState`) and a fake pipeline/notes-writer via
/// `pipelineFactory`/`notesWriterFactory`, so nothing here touches a real
/// cloud provider, the real Keychain, or the user's real UserDefaults/output
/// directory.
@MainActor
@Suite struct AppStateProcessingTests {
    /// A cloud job whose fake pipeline blocks mid-transcription: cancelling it
    /// must flip to idle/canceled synchronously (no offline job is active), and
    /// releasing the fake afterwards — letting it complete "late" — must not
    /// overwrite that with "Notes ready.". This is the P0-2 generation-token
    /// guard processCloud's success path relies on.
    @Test func canceledCloudJobSuppressesStaleCompletion() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        let dir = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-a")

        let gate = Gate()
        state.pipelineFactory = { _, _, _, _, _, _ in
            FakePipeline(gate: gate, transcript: "[00:01] hello", notesResult: .success(("polished", "summary")))
        }

        state.process(dir)
        #expect(state.state == .processing)
        await gate.waitForEntry()

        state.cancelProcessing()
        #expect(state.state == .idle)
        #expect(state.status == L.canceledMessage.en)

        await gate.release()
        // Give the now-superseded task a chance to run to completion (or throw
        // CancellationError) and hit its generation-token guard.
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.state == .idle)
        #expect(state.status == L.canceledMessage.en)
    }

    /// Job A (generateMinutes, blocked on a fake NotesWriter) is superseded by
    /// Job B (generateMinutes on a different meeting) before A finishes. B must
    /// complete normally; A finishing afterwards must not stomp B's
    /// state/status, and must fail its own `Task.checkCancellation()` (it was
    /// cancelled when B started) rather than report success.
    @Test func supersededGenerateMinutesJobDoesNotOverwriteNewerJob() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        let dirA = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-a",
                                                          transcript: "[00:01] transcript A")
        let dirB = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-b",
                                                          transcript: "[00:01] transcript B")

        let gateA = Gate()
        final class CallCount { var value = 0 }
        let calls = CallCount()
        state.notesWriterFactory = { _, _, _, _ in
            calls.value += 1
            if calls.value == 1 {
                return FakeNotesWriter(label: "writer-a", gate: gateA, result: .success(("polished-A", "summary-A")))
            } else {
                return FakeNotesWriter(label: "writer-b", result: .success(("polished-B", "summary-B")))
            }
        }

        state.generateMinutes(dirA)
        await gateA.waitForEntry()
        #expect(state.state == .processing)

        state.generateMinutes(dirB)
        try await AppStateTestSupport.waitUntil { state.state == .idle }
        #expect(state.status == L.minutesReadyMessage.en)
        #expect(try String(contentsOf: dirB.appendingPathComponent("summary.md"), encoding: .utf8)
            .contains("summary-B"))

        await gateA.release()
        try await Task.sleep(for: .milliseconds(100))
        // B's completion must still stand — A's late completion (superseded,
        // and cancelled) must not have touched state/status again.
        #expect(state.state == .idle)
        #expect(state.status == L.minutesReadyMessage.en)
    }

    /// A cloud job whose transcription succeeds but whose notes stage throws:
    /// `transcript.md` must survive (MeetingProcessor.process writes it before
    /// the notes stage ever runs), and the status must be the distinct
    /// "transcript saved, notes failed" message rather than a generic failure.
    @Test func notesFailureAfterTranscriptionPersistsTranscript() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        let dir = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-a")
        let transcriptText = "[00:01] Speaker: important transcript"

        state.pipelineFactory = { _, _, _, _, _, _ in
            FakePipeline(transcript: transcriptText,
                        notesResult: .failure(FakeError(message: "notes provider exploded")))
        }

        state.process(dir)
        try await AppStateTestSupport.waitUntil { state.state == .error }

        #expect(state.status == L.transcriptSavedNotesFailed.en)
        #expect(state.lastError?.contains("notes provider exploded") == true)
        let transcript = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(transcript.contains(transcriptText))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("polished.md").path))
    }
}
