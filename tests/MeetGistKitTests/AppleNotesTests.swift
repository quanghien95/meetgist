// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

private enum AppleTestError: Error { case failed }

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

@Suite struct AppleNotesTests {
    @Test func appleProviderRequiresNoAPIKeyAndCloudProvidersStayUnchanged() throws {
        let apple = try #require(ProviderCatalog.builtIn.first { $0.id == "apple-foundation-models" })
        #expect(apple.notesStyle == .apple)
        #expect(apple.transcribeStyle == nil)
        #expect(try Pipelines.makeNotesWriter(notes: apple, notesKey: nil).label == "Apple On-Device")

        #expect(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle == .gemini)
        #expect(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle == .chat)
        #expect(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle == .chat)
    }

    @Test func appleAvailabilityReasonsAreUseful() {
        #expect(!AppleFoundationModelsAvailability.modelNotReady.isReady)
        #expect(AppleFoundationModelsAvailability.modelNotReady.message.contains("not ready"))
        #expect(AppleFoundationModelsAvailability.appleIntelligenceNotEnabled.message
            .contains("System Settings"))
#if !canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            #expect(AppleFoundationModelsSupport.availability == .frameworkUnavailable)
        }
#endif
    }

    @Test func unavailableAppleProviderReturnsItsReasonWithoutCloudFallback() async throws {
        let availability = AppleFoundationModelsSupport.availability
        guard !availability.isReady else { return }
        let writer = AppleFoundationModelsNotesWriter()

        do {
            _ = try await writer.notes(transcript: "Existing transcript", progress: { _ in })
            Issue.record("Expected unavailable Apple Foundation Models to fail")
        } catch let error as PipelineError {
            #expect(error.localizedDescription == availability.message)
        }
    }

    @Test func appleWriterProducesExistingMinutesAndSummaryContract() async throws {
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

        #expect(result.polished.contains("# Meeting Minutes"))
        #expect(result.summary.contains("## Key Decisions"))
    }

    @Test func appleWriterChunksLongTranscriptBeforeFinalNotesRequest() async throws {
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

        #expect(calls.count > 2)
        #expect(calls.dropLast().contains {
            $0.instructions.contains("Extract a compact, factual record")
        })
        #expect(calls.dropLast().allSatisfy {
            $0.prompt.count <= AppleFoundationModelsNotesWriter.sourceChunkCharacters
        })
        #expect(try #require(calls.last).prompt.count
                <= AppleFoundationModelsNotesWriter.finalSourceCharacters)
        #expect(result.polished.contains("Retained fact"))
        #expect(result.summary.contains("Key Decisions"))
    }

    @Test func appleContextSplitterBoundsOversizedLines() {
        let text = String(repeating: "越", count: 25) + "\nshort line"
        let chunks = AppleFoundationModelsNotesWriter.splitForContext(text, limit: 10)

        #expect(chunks.joined().filter { !$0.isWhitespace }
                == text.filter { !$0.isWhitespace })
        #expect(chunks.allSatisfy { $0.count <= 10 })
    }

    @Test func appleFailureLeavesExistingTranscriptUntouchedAndDoesNotFallback() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-apple-notes-failure")
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
            Issue.record("Expected the injected Apple provider failure")
        } catch AppleTestError.failed { }

        #expect(try String(contentsOf: root.appendingPathComponent("transcript.md")) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("polished.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.md").path))
    }
}
