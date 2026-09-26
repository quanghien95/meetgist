// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

private enum QwenTestError: Error { case failed }

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

@Suite struct QwenNotesTests {
    @Test func qwenProviderIsNotesOnlyAndCloudProvidersStayUnchanged() throws {
        let qwen = try #require(ProviderCatalog.builtIn.first { $0.id == "qwen-mlx-local" })
        #expect(qwen.notesStyle == .qwenMLX)
        #expect(qwen.notesModel == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(qwen.transcribeStyle == nil)
        #expect(try Pipelines.makeNotesWriter(notes: qwen, notesKey: nil).label
                == LocalNotesRuntimeManager.activeModel.displayLabel)

        #expect(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle == .gemini)
        #expect(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle == .chat)
        #expect(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle == .chat)
    }

    @Test func qwenWriterUsesExistingOutputContractAndTemplateMode() async throws {
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
        let request = try #require(recordedRequest)

        #expect(result.polished == response.polished)
        #expect(result.summary == response.summary)
        #expect(request.isTemplate)
        #expect(request.instructions.contains("# Mẫu"))
        #expect(request.transcript == "[00:01] An: Chốt phương án.")
    }

    @Test func qwenWriterPassesConfiguredLanguageIntoInstructions() async throws {
        let recorder = QwenRequestRecorder()
        let response = QwenNotesResponse(polished: "p", summary: "s", metrics: nil)
        let writer = QwenMLXNotesWriter(
            language: "English",
            generator: StubQwenGenerator(recorder: recorder, response: response))

        _ = try await writer.notes(transcript: "[00:01] An: test.", progress: { _ in })
        let request = try #require(await recorder.snapshot())

        #expect(request.instructions.contains("LANGUAGE = English"))
    }

    @Test func defaultNotesLanguageIsVietnamese() {
        #expect(Prompts.defaultNotesLanguage == "Vietnamese")
    }

    @Test func qwenResultJSONPreservesVietnameseAndMarkdown() throws {
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

        #expect(decoded.polished == original.polished)
        #expect(decoded.summary == original.summary)
        #expect(decoded.metrics?.modelLoadSeconds == 2.1)
        #expect(decoded.metrics?.prefillSeconds == 1.7)
        #expect(decoded.metrics?.generationSeconds == 8.4)
        #expect(decoded.metrics?.generationTokensPerSecond == 57.1)
        #expect(decoded.metrics?.sourceChunks == 3)
    }

    @Test func qwenMetricsDecodeThePreviousSchema() throws {
        let legacy = """
        {"elapsedSeconds":12.5,"peakMemoryGB":6.2,"promptTokens":1200,
        "generationTokens":480,"sourceChunks":3}
        """
        let decoded = try JSONDecoder().decode(QwenNotesMetrics.self,
                                                from: Data(legacy.utf8))

        #expect(decoded.elapsedSeconds == 12.5)
        #expect(decoded.modelLoadSeconds == nil)
        #expect(decoded.prefillSeconds == nil)
        #expect(decoded.generationSeconds == nil)
        #expect(decoded.generationTokensPerSecond == nil)
        #expect(decoded.wallClockSeconds == nil)
        #expect(decoded.numberOfLLMCalls == nil)
    }

    @Test func qwenMetricsDecodePhase1Instrumentation() throws {
        let json = """
        {"elapsedSeconds":12.5,"peakMemoryGB":6.2,"promptTokens":1200,
        "generationTokens":480,"sourceChunks":1,"wallClockSeconds":14.2,
        "numberOfLLMCalls":1,"mapCalls":0,"reduceCalls":0,"finalCalls":1,
        "usedDirectContext":true}
        """
        let decoded = try JSONDecoder().decode(QwenNotesMetrics.self, from: Data(json.utf8))

        #expect(decoded.wallClockSeconds == 14.2)
        #expect(decoded.numberOfLLMCalls == 1)
        #expect(decoded.mapCalls == 0)
        #expect(decoded.reduceCalls == 0)
        #expect(decoded.finalCalls == 1)
        #expect(decoded.usedDirectContext == true)
    }

    @Test func localNotesModelConfigIsQwen3_4BWithPinnedRevisionAndSensibleBudgets() {
        let config = LocalNotesRuntimeManager.activeModel
        #expect(config.modelID == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(!config.modelRevision.isEmpty)
        #expect(config.modelRevision.count == 40, "revision must be a pinned commit sha, not a branch")
        #expect(config.directSourceTokens >= 24_000)
        #expect(config.directSourceTokens <= 32_000)
        #expect(config.directSourceTokens < 262_144, "must stay well under the model's max context")
        #expect(config.temperature == 0.7)
        #expect(config.topP == 0.8)
        #expect(config.topK == 20)
    }

    @Test func qwenFailureDoesNotFallbackOrModifyTranscript() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-qwen-notes-failure")
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
            Issue.record("Expected the injected Qwen failure")
        } catch QwenTestError.failed { }

        #expect(try String(contentsOf: root.appendingPathComponent("transcript.md")) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
    }

    @Test @MainActor func localNotesRuntimeReadinessIsIndependentFromWhisperRuntime() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-qwen-runtime")
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
        #expect(runtime.state == .ready)
        #expect(LocalNotesRuntimeManager.isReady(at: root))
        #expect(runtime.root.path.contains("meetgist-qwen-runtime"))
        #expect(!runtime.root.path.contains("OfflineWhisper"))
    }
}
