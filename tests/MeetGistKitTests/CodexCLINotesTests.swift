// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

private enum CodexTestError: Error { case failed }

private actor CodexCallRecorder {
    private var calls: [(prompt: String, effort: String)] = []
    func append(prompt: String, effort: String) { calls.append((prompt, effort)) }
    func snapshot() -> [(prompt: String, effort: String)] { calls }
}

private struct StubCodexGenerator: CodexCLIGenerating {
    let recorder: CodexCallRecorder
    let response: String
    func generate(prompt: String, reasoningEffort: String) async throws -> String {
        await recorder.append(prompt: prompt, effort: reasoningEffort)
        return response
    }
}

private struct FailingCodexGenerator: CodexCLIGenerating {
    func generate(prompt: String, reasoningEffort: String) async throws -> String {
        throw CodexTestError.failed
    }
}

@Suite struct CodexCLINotesTests {
    @Test func codexCLIProviderIsNotesOnlyCloudAndNotTreatedAsLocal() throws {
        let codex = try #require(ProviderCatalog.builtIn.first { $0.id == "codex-cli" })
        #expect(codex.notesStyle == .codexCLI)
        #expect(codex.transcribeStyle == nil)
        #expect(codex.notesReasoningEffort == "none")
        #expect(try Pipelines.makeNotesWriter(notes: codex, notesKey: nil).label
                == "Codex CLI · gpt-6-luna")
    }

    @Test func codexCLIWriterPassesReasoningEffortAndUsesExistingOutputContract() async throws {
        let recorder = CodexCallRecorder()
        let response = "---POLISHED---\n# Biên bản\n- Quyết định\n---SUMMARY---\n## Tóm tắt\n- Quyết định"
        let writer = CodexCLINotesWriter(
            reasoningEffort: "medium",
            generator: StubCodexGenerator(recorder: recorder, response: response))

        let result = try await writer.notes(
            transcript: "[00:01] An: Chốt phương án.", progress: { _ in })
        let calls = await recorder.snapshot()

        #expect(result.polished == "# Biên bản\n- Quyết định")
        #expect(result.summary == "## Tóm tắt\n- Quyết định")
        #expect(calls.count == 1)
        #expect(calls.first?.effort == "medium")
        #expect(calls.first?.prompt.contains("[00:01] An: Chốt phương án.") == true)
    }

    @Test func codexCLIWriterPassesConfiguredLanguageIntoPrompt() async throws {
        let recorder = CodexCallRecorder()
        let response = "---POLISHED---\np\n---SUMMARY---\ns"
        let writer = CodexCLINotesWriter(
            language: "English",
            generator: StubCodexGenerator(recorder: recorder, response: response))

        _ = try await writer.notes(transcript: "[00:01] An: test.", progress: { _ in })
        let calls = await recorder.snapshot()

        #expect(calls.first?.prompt.contains("LANGUAGE = English") == true)
    }

    @Test func codexCLIWriterDefaultsToConfiguredDefaultLanguage() async throws {
        let recorder = CodexCallRecorder()
        let response = "---POLISHED---\np\n---SUMMARY---\ns"
        let writer = CodexCLINotesWriter(
            generator: StubCodexGenerator(recorder: recorder, response: response))

        _ = try await writer.notes(transcript: "[00:01] An: test.", progress: { _ in })
        let calls = await recorder.snapshot()

        #expect(calls.first?.prompt.contains("LANGUAGE = \(Prompts.defaultNotesLanguage)") == true)
    }

    @Test func codexCLIWriterFallsBackToNoneForInvalidStoredEffort() throws {
        let writer = CodexCLINotesWriter(reasoningEffort: "not-a-real-effort",
                                         generator: FailingCodexGenerator())
        #expect(writer.reasoningEffort == "none")
    }

    @Test func codexCLITemplateModeReturnsRawOutputForBothSections() async throws {
        let recorder = CodexCallRecorder()
        let writer = CodexCLINotesWriter(
            template: "# Mẫu",
            generator: StubCodexGenerator(recorder: recorder, response: "# Đã điền mẫu"))

        let result = try await writer.notes(transcript: "[00:01] An: nội dung.", progress: { _ in })

        #expect(result.polished == "# Đã điền mẫu")
        #expect(result.summary == "# Đã điền mẫu")
        let calls = await recorder.snapshot()
        #expect(calls.first?.prompt.contains("# Mẫu") == true)
    }

    @Test func codexCLIMissingMarkersRaisesRatherThanReturningPartialNotes() async throws {
        let recorder = CodexCallRecorder()
        let writer = CodexCLINotesWriter(
            generator: StubCodexGenerator(recorder: recorder, response: "no markers at all"))

        do {
            _ = try await writer.notes(transcript: "[00:01] An: nội dung.", progress: { _ in })
            Issue.record("Expected a badResponse error for missing POLISHED/SUMMARY markers")
        } catch PipelineError.badResponse { }
    }

    @Test func codexCLIFailureDoesNotFallbackOrModifyTranscript() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-codex-notes-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = "[00:01] Me: Keep this transcript unchanged."
        try original.write(to: root.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)
        let writer = CodexCLINotesWriter(generator: FailingCodexGenerator())

        do {
            _ = try await MeetingProcessor.generateNotes(
                sessionDir: root, writer: writer, providerName: "Codex CLI",
                progress: { _ in })
            Issue.record("Expected the injected Codex CLI failure")
        } catch CodexTestError.failed { }

        #expect(try String(contentsOf: root.appendingPathComponent("transcript.md")) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
    }

    @Test func codexCLIEmptyTranscriptRaisesBeforeInvokingGenerator() async throws {
        let recorder = CodexCallRecorder()
        let writer = CodexCLINotesWriter(
            generator: StubCodexGenerator(recorder: recorder, response: "unused"))

        do {
            _ = try await writer.notes(transcript: "   \n  ", progress: { _ in })
            Issue.record("Expected badResponse for empty transcript")
        } catch PipelineError.badResponse { }

        #expect(await recorder.snapshot().isEmpty)
    }
}
