// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import MeetGistKit

final class OfflineJobTests: XCTestCase {
    private enum AppleTestError: Error { case failed }

    private struct StubAppleGenerator: AppleFoundationModelsGenerating {
        let output: String
        func generate(instructions: String, prompt: String) async throws -> String { output }
    }

    private struct FailingAppleGenerator: AppleFoundationModelsGenerating {
        func generate(instructions: String, prompt: String) async throws -> String {
            throw AppleTestError.failed
        }
    }

    private struct TranscriptEchoWriter: NotesWriter {
        let label = "Test notes"
        func notes(transcript: String,
                   progress: @escaping @Sendable (String) -> Void) async throws
            -> (polished: String, summary: String) {
            progress("Writing test notes")
            return ("polished: \(transcript)", "summary: \(transcript)")
        }
    }

    func testRecoveryRemovesTemporaryAndRebuildsProgressFromValidParts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-offline-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineJobStore(sessionDir: root)
        try FileManager.default.createDirectory(at: store.partsDir, withIntermediateDirectories: true)
        var state = OfflineJobState(
            jobID: "offline-test", sessionID: root.lastPathComponent,
            status: .transcribing, config: OfflineJobConfig(),
            tracks: ["system": OfflineTrackState(durationSeconds: 601)])
        try store.save(state)

        let first = OfflinePart(
            schemaVersion: 1, jobID: state.jobID, sessionID: state.sessionID,
            configID: state.configID, track: "system", chunkIndex: 0,
            coreStartSeconds: 0, coreEndSeconds: 300, processingSeconds: 120,
            segments: [])
        let data = try JSONEncoder().encode(first)
        try data.write(to: store.partsDir.appendingPathComponent("system-0000.json"))
        try Data("broken".utf8).write(to: store.partsDir.appendingPathComponent("system-0001.json"))
        let abandoned = store.partsDir.appendingPathComponent("system-0002.json.tmp")
        try Data("partial".utf8).write(to: abandoned)

        state = try store.recover()
        XCTAssertEqual(state.status, .pending)
        XCTAssertEqual(state.progress.processedSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(state.progress.totalSeconds, 601, accuracy: 0.001)
        XCTAssertEqual(state.progress.rollingRTF ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(state.progress.etaSeconds, 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testOfflineProviderDoesNotBecomeANotesProvider() {
        let offline = ProviderCatalog.builtIn.first { $0.id == "offline-whisper" }
        XCTAssertEqual(offline?.transcribeStyle, "offline")
        XCTAssertEqual(offline?.transcribeModel, "mlx-community/whisper-large-v3-mlx")
        XCTAssertEqual(offline?.canWriteNotes, false)
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle, "gemini")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle, "chat")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle, "chat")
    }

    func testAppleProviderRequiresNoAPIKeyAndCloudProvidersStayUnchanged() throws {
        let apple = try XCTUnwrap(ProviderCatalog.builtIn.first { $0.id == "apple-foundation-models" })
        XCTAssertEqual(apple.notesStyle, "apple")
        XCTAssertNil(apple.transcribeStyle)
        XCTAssertEqual(try Pipelines.makeNotesWriter(notes: apple, notesKey: nil).label, "Apple On-Device")

        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle, "gemini")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle, "chat")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle, "chat")
    }

    func testAppleAvailabilityReasonsAreUseful() {
        XCTAssertFalse(AppleFoundationModelsAvailability.modelNotReady.isReady)
        XCTAssertTrue(AppleFoundationModelsAvailability.modelNotReady.message.contains("not ready"))
        XCTAssertTrue(AppleFoundationModelsAvailability.appleIntelligenceNotEnabled.message
            .contains("System Settings"))
#if !canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(AppleFoundationModelsSupport.availability, .frameworkUnavailable)
        }
#endif
    }

    func testUnavailableAppleProviderReturnsItsReasonWithoutCloudFallback() async throws {
        let availability = AppleFoundationModelsSupport.availability
        guard !availability.isReady else { return }
        let writer = AppleFoundationModelsNotesWriter()

        do {
            _ = try await writer.notes(transcript: "Existing transcript", progress: { _ in })
            XCTFail("Expected unavailable Apple Foundation Models to fail")
        } catch let error as PipelineError {
            XCTAssertEqual(error.localizedDescription, availability.message)
        }
    }

    func testAppleWriterProducesExistingMinutesAndSummaryContract() async throws {
        let raw = """
        ---POLISHED---
        # Meeting Minutes
        ## Discussion
        - Me: Ship the local provider.
        ---SUMMARY---
        ## Key Decisions
        - Ship the local provider.
        """
        let writer = AppleFoundationModelsNotesWriter(
            generator: StubAppleGenerator(output: raw))

        let result = try await writer.notes(
            transcript: "[00:01] Me: Ship the local provider.", progress: { _ in })

        XCTAssertTrue(result.polished.contains("# Meeting Minutes"))
        XCTAssertTrue(result.summary.contains("## Key Decisions"))
    }

    func testAppleFailureLeavesExistingTranscriptUntouchedAndDoesNotFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-apple-notes-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = "[00:01] Me: Keep this transcript unchanged."
        try original.write(to: root.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)
        let writer = AppleFoundationModelsNotesWriter(generator: FailingAppleGenerator())

        do {
            _ = try await MeetingProcessor.generateNotes(
                sessionDir: root, writer: writer, providerName: "Apple On-Device",
                progress: { _ in })
            XCTFail("Expected the injected Apple provider failure")
        } catch AppleTestError.failed { }

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript.md")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
    }

    func testMeetingRenamePreservesSessionDirectoryAndTranscriptIsNotNotes() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-meeting-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let session = output.appendingPathComponent("2026-08-22-1200-Original")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("mic.m4a"))
        try Data("transcript".utf8).write(to: session.appendingPathComponent("transcript.md"))

        var meeting = try XCTUnwrap(MeetingStore.list(in: output).first)
        XCTAssertEqual(meeting.title, "Original")
        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertFalse(meeting.hasNotes)
        try MeetingStore.rename(meeting, to: "Customer Review")

        meeting = try XCTUnwrap(MeetingStore.list(in: output).first)
        XCTAssertEqual(meeting.title, "Customer Review")
        XCTAssertEqual(meeting.dir, session)
        XCTAssertEqual(meeting.id, session.lastPathComponent)

        try Data("summary".utf8).write(to: session.appendingPathComponent("summary.md"))
        XCTAssertFalse(try XCTUnwrap(MeetingStore.list(in: output).first).hasNotes)
        try Data("minutes".utf8).write(to: session.appendingPathComponent("polished.md"))
        XCTAssertTrue(try XCTUnwrap(MeetingStore.list(in: output).first).hasNotes)
    }

    @MainActor
    func testWorkerExitIsConfirmedBeforeRecordingAndPauseResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-offline-coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\ntrap 'exit 75' TERM INT\nwhile true; do sleep 1; done\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))

        let session = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let runtime = OfflineRuntimeManager(root: runtimeRoot)
        XCTAssertEqual(runtime.state, .ready)
        let coordinator = OfflineJobCoordinator(runtime: runtime)
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        XCTAssertNotNil(coordinator.activeSessionID)
        await coordinator.stopForRecording()
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertEqual(coordinator.state(for: session.lastPathComponent)?.status, .pending)

        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        await coordinator.pause()
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertEqual(coordinator.state(for: session.lastPathComponent)?.status, .paused)

        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        XCTAssertEqual(coordinator.state(for: session.lastPathComponent)?.status, .transcribing)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.state(for: session.lastPathComponent)?.status, .canceled)
    }

    @MainActor
    func testConfirmedResetDeletesOnlyGeneratedTranscriptionArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-offline-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcription = root.appendingPathComponent("transcription/parts")
        try FileManager.default.createDirectory(at: transcription, withIntermediateDirectories: true)
        for name in ["system.m4a", "mic.m4a", "sync_map.json", "transcript.md", "summary.md"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("part".utf8).write(to: transcription.appendingPathComponent("system-0000.json"))

        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: root.appendingPathComponent("runtime")))
        try coordinator.resetTranscription(sessionDir: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcription").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))
        for name in ["system.m4a", "mic.m4a", "sync_map.json", "summary.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    func testGenerateMinutesConsumesExistingOfflineTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-offline-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcript = "[00:01] Speaker: Benchmark decision"
        try transcript.write(to: root.appendingPathComponent("transcript.md"),
                             atomically: true, encoding: .utf8)

        let result = try await MeetingProcessor.generateNotes(
            sessionDir: root, writer: TranscriptEchoWriter(), providerName: "Test provider",
            progress: { _ in })

        XCTAssertEqual(result.polished, "polished: \(transcript)")
        XCTAssertEqual(result.summary, "summary: \(transcript)")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("polished.md"))
            .contains(transcript))
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("postprocess_meta.json"))) as? [String: String]
        XCTAssertEqual(metadata?["provider"], "Test provider")
        XCTAssertEqual(metadata?["model"], "Test notes")
        XCTAssertNil(metadata?["transcription"])
    }
}
