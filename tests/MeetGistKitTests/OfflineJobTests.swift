// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import MeetGistKit

final class OfflineJobTests: XCTestCase {
    private enum AppleTestError: Error { case failed }
    private enum QwenTestError: Error { case failed }

    private actor AppleCallRecorder {
        private var values: [(instructions: String, prompt: String)] = []
        func append(instructions: String, prompt: String) {
            values.append((instructions, prompt))
        }
        func snapshot() -> [(instructions: String, prompt: String)] { values }
    }

    private struct StubAppleGenerator: AppleFoundationModelsGenerating {
        let output: String
        func generate(instructions: String, prompt: String) async throws -> String { output }
    }

    private struct FailingAppleGenerator: AppleFoundationModelsGenerating {
        func generate(instructions: String, prompt: String) async throws -> String {
            throw AppleTestError.failed
        }
    }

    private struct ChunkingAppleGenerator: AppleFoundationModelsGenerating {
        let recorder: AppleCallRecorder
        let finalOutput: String

        func generate(instructions: String, prompt: String) async throws -> String {
            await recorder.append(instructions: instructions, prompt: prompt)
            if instructions.contains("Extract a compact, factual record") {
                return "- [00:01] Me: retained fact"
            }
            if instructions.contains("Condense these partial meeting facts") {
                return "- [00:01] Me: reduced retained fact"
            }
            return finalOutput
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

    private actor QwenRequestRecorder {
        private var request: QwenNotesRequest?
        func set(_ request: QwenNotesRequest) { self.request = request }
        func snapshot() -> QwenNotesRequest? { request }
    }

    private struct StubQwenGenerator: QwenMLXGenerating {
        let recorder: QwenRequestRecorder
        let response: QwenNotesResponse
        func generate(_ request: QwenNotesRequest) async throws -> QwenNotesResponse {
            await recorder.set(request)
            return response
        }
    }

    private struct FailingQwenGenerator: QwenMLXGenerating {
        func generate(_ request: QwenNotesRequest) async throws -> QwenNotesResponse {
            throw QwenTestError.failed
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

    func testQwenProviderIsNotesOnlyAndCloudProvidersStayUnchanged() throws {
        let qwen = try XCTUnwrap(ProviderCatalog.builtIn.first { $0.id == "qwen-mlx-local" })
        XCTAssertEqual(qwen.notesStyle, "qwen-mlx")
        XCTAssertEqual(qwen.notesModel, "mlx-community/Qwen3-8B-4bit")
        XCTAssertNil(qwen.transcribeStyle)
        XCTAssertEqual(try Pipelines.makeNotesWriter(notes: qwen, notesKey: nil).label,
                       "Qwen3-8B-4bit · MLX-LM")

        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle, "gemini")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle, "chat")
        XCTAssertEqual(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle, "chat")
    }

    func testExistingCloudNotesStillRequireKeysAndUseTheirConfiguredModels() throws {
        for id in ["gemini", "openai", "groq"] {
            let provider = try XCTUnwrap(ProviderCatalog.builtIn.first { $0.id == id })
            XCTAssertThrowsError(try Pipelines.makeNotesWriter(notes: provider, notesKey: nil))
            let writer = try Pipelines.makeNotesWriter(notes: provider, notesKey: "test-key")
            let model = try XCTUnwrap(provider.notesModel)
            XCTAssertEqual(writer.label, model)
        }
    }

    func testQwenWriterUsesExistingOutputContractAndTemplateMode() async throws {
        let recorder = QwenRequestRecorder()
        let response = QwenNotesResponse(
            polished: "# Biên bản\n- Quyết định",
            summary: "## Tóm tắt\n- Quyết định",
            metrics: nil)
        let writer = QwenMLXNotesWriter(
            template: "# Mẫu",
            generator: StubQwenGenerator(recorder: recorder, response: response))

        let result = try await writer.notes(
            transcript: "[00:01] An: Chốt phương án.", progress: { _ in })
        let recordedRequest = await recorder.snapshot()
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(result.polished, response.polished)
        XCTAssertEqual(result.summary, response.summary)
        XCTAssertTrue(request.isTemplate)
        XCTAssertTrue(request.instructions.contains("# Mẫu"))
        XCTAssertEqual(request.transcript, "[00:01] An: Chốt phương án.")
    }

    func testQwenResultJSONPreservesVietnameseAndMarkdown() throws {
        let original = QwenNotesResponse(
            polished: "# Biên bản\n- An: Chốt phương án \"A/B\".",
            summary: "## Tóm tắt\n- Không gửi dữ liệu lên cloud.",
            metrics: QwenNotesMetrics(elapsedSeconds: 12.5, modelLoadSeconds: 2.1,
                                      prefillSeconds: 1.7, generationSeconds: 8.4,
                                      generationTokensPerSecond: 57.1, peakMemoryGB: 6.2,
                                      promptTokens: 1_200, generationTokens: 480,
                                      sourceChunks: 3))

        let decoded = try JSONDecoder().decode(
            QwenNotesResponse.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.polished, original.polished)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.metrics?.modelLoadSeconds, 2.1)
        XCTAssertEqual(decoded.metrics?.prefillSeconds, 1.7)
        XCTAssertEqual(decoded.metrics?.generationSeconds, 8.4)
        XCTAssertEqual(decoded.metrics?.generationTokensPerSecond, 57.1)
        XCTAssertEqual(decoded.metrics?.sourceChunks, 3)
    }

    func testQwenMetricsDecodeThePreviousSchema() throws {
        let legacy = """
        {"elapsedSeconds":12.5,"peakMemoryGB":6.2,"promptTokens":1200,
        "generationTokens":480,"sourceChunks":3}
        """
        let decoded = try JSONDecoder().decode(QwenNotesMetrics.self,
                                                from: Data(legacy.utf8))

        XCTAssertEqual(decoded.elapsedSeconds, 12.5)
        XCTAssertNil(decoded.modelLoadSeconds)
        XCTAssertNil(decoded.prefillSeconds)
        XCTAssertNil(decoded.generationSeconds)
        XCTAssertNil(decoded.generationTokensPerSecond)
    }

    func testQwenFailureDoesNotFallbackOrModifyTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-qwen-notes-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = "[00:01] Me: Keep this transcript unchanged."
        try original.write(to: root.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)
        let writer = QwenMLXNotesWriter(generator: FailingQwenGenerator())

        do {
            _ = try await MeetingProcessor.generateNotes(
                sessionDir: root, writer: writer, providerName: "Local Qwen",
                progress: { _ in })
            XCTFail("Expected the injected Qwen failure")
        } catch QwenTestError.failed { }

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript.md")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
    }

    @MainActor
    func testLocalNotesRuntimeReadinessIsIndependentFromWhisperRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-qwen-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model"),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: python.path)
        try Data("{}".utf8).write(to: root.appendingPathComponent("model/config.json"))
        try Data().write(to: root.appendingPathComponent("model/model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("ready.json"))

        let runtime = LocalNotesRuntimeManager(root: root)
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertTrue(LocalNotesRuntimeManager.isReady(at: root))
        XCTAssertTrue(runtime.root.path.contains("meetgist-qwen-runtime"))
        XCTAssertFalse(runtime.root.path.contains("OfflineWhisper"))
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

    func testAppleWriterChunksLongTranscriptBeforeFinalNotesRequest() async throws {
        let raw = """
        ---POLISHED---
        # Meeting Minutes
        - Retained fact
        ---SUMMARY---
        ## Key Decisions
        - Retained fact
        """
        let recorder = AppleCallRecorder()
        let writer = AppleFoundationModelsNotesWriter(
            generator: ChunkingAppleGenerator(recorder: recorder, finalOutput: raw))
        let longTranscript = (0..<200).map {
            "[00:\(String(format: "%02d", $0 % 60))] Me: Important decision number \($0)."
        }.joined(separator: "\n")

        let result = try await writer.notes(transcript: longTranscript, progress: { _ in })
        let calls = await recorder.snapshot()

        XCTAssertGreaterThan(calls.count, 2)
        XCTAssertTrue(calls.dropLast().contains {
            $0.instructions.contains("Extract a compact, factual record")
        })
        XCTAssertTrue(calls.dropLast().allSatisfy {
            $0.prompt.count <= AppleFoundationModelsNotesWriter.sourceChunkCharacters
        })
        XCTAssertLessThanOrEqual(try XCTUnwrap(calls.last).prompt.count,
                                 AppleFoundationModelsNotesWriter.finalSourceCharacters)
        XCTAssertTrue(result.polished.contains("Retained fact"))
        XCTAssertTrue(result.summary.contains("Key Decisions"))
    }

    func testAppleContextSplitterBoundsOversizedLines() {
        let text = String(repeating: "越", count: 25) + "\nshort line"
        let chunks = AppleFoundationModelsNotesWriter.splitForContext(text, limit: 10)

        XCTAssertEqual(chunks.joined().filter { !$0.isWhitespace },
                       text.filter { !$0.isWhitespace })
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 10 })
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

        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate],
                                              ofItemAtPath: session.path)

        var meeting = try XCTUnwrap(MeetingStore.list(in: output).first)
        XCTAssertEqual(meeting.title, "Original")
        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertFalse(meeting.hasNotes)
        try MeetingStore.rename(meeting, to: "Customer Review")

        meeting = try XCTUnwrap(MeetingStore.list(in: output).first)
        XCTAssertEqual(meeting.title, "Customer Review")
        XCTAssertEqual(meeting.dir, session)
        XCTAssertEqual(meeting.id, session.lastPathComponent)
        XCTAssertEqual(try XCTUnwrap(meeting.date).timeIntervalSince1970,
                       originalDate.timeIntervalSince1970, accuracy: 1)

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
    func testWorkerThatIgnoresTerminationIsForceStopped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-offline-force-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\ntrap '' TERM INT\nwhile true; do sleep 1; done\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))
        let session = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: runtimeRoot))
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())

        let clock = ContinuousClock()
        let started = clock.now
        await coordinator.stopForRecording()

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertEqual(coordinator.state(for: session.lastPathComponent)?.status, .pending)
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
