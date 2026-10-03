// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

// MARK: - Prompt builder (plan §7.1/§7.2)

@Suite struct LiveCopilotV2PromptTests {
    private func turn(_ id: Int, _ text: String, start: Double) -> LiveTranscriptTurn {
        LiveTranscriptTurn(id: id, track: .speaker, startedAt: start, endedAt: start + 1, text: text)
    }

    @Test func systemPromptPropagatesTheRequestedLanguage() {
        let prompt = LiveCopilotPrompts.answerSystemPrompt(language: "Vietnamese")
        #expect(prompt.contains("Vietnamese"))
    }

    @Test func userContentIncludesQuestionStateAndTurnsButNoContextSectionWhenNoneGiven() {
        let state = LiveCopilotPrompts.CompactStateView(topic: "Q3 planning", keyPoints: [], openQuestions: [], decisions: [], actionItems: [])
        let content = LiveCopilotPrompts.answerUserContent(
            language: "English", question: "Who owns the migration?", state: state,
            turns: [turn(1, "Alice will handle the ERP migration.", start: 0)],
            context: [], bounds: LiveCopilotPrompts.Bounds())

        #expect(content.contains("LANGUAGE: English"))
        #expect(content.contains("QUESTION: Who owns the migration?"))
        #expect(content.contains("Q3 planning"))
        #expect(content.contains("TURNS"))
        #expect(content.contains("Alice will handle the ERP migration."))
        #expect(!content.contains("CONTEXT"))
    }

    @Test func userContentIncludesContextSectionWhenSnippetsAreGiven() {
        let state = LiveCopilotPrompts.CompactStateView(topic: "", keyPoints: [], openQuestions: [], decisions: [], actionItems: [])
        let content = LiveCopilotPrompts.answerUserContent(
            language: "English", question: "What's the target date?", state: state, turns: [],
            context: [ContextSnippet(source: "roadmap.md", text: "Target date is October 15.")],
            bounds: LiveCopilotPrompts.Bounds())

        #expect(content.contains("CONTEXT"))
        #expect(content.contains("roadmap.md"))
        #expect(content.contains("Target date is October 15."))
    }

    @Test func turnsAreBoundedByCountAndCharCapLikeTheSemanticPrompt() {
        let state = LiveCopilotPrompts.CompactStateView(topic: "", keyPoints: [], openQuestions: [], decisions: [], actionItems: [])
        let longText = String(repeating: "word ", count: 40)
        let turns = (0..<10).map { turn($0, longText, start: Double($0) * 2) }
        let content = LiveCopilotPrompts.answerUserContent(
            language: "English", question: "q", state: state, turns: turns, context: [],
            bounds: LiveCopilotPrompts.Bounds(maxRecentTurns: 3, maxRecentTurnsChars: 120))
        #expect(!content.contains("[00:00]"))
    }
}

// MARK: - Answer parser (plan §7.1/§7.2)

@Suite struct LiveAssistAnswerParserTests {
    @Test func parsesAWellFormedAnswer() throws {
        let json = """
        {"answer": "Yes, Friday is confirmed.", "known_from_meeting": ["Friday is confirmed"],
         "from_context": [], "assumptions": [], "confidence": "high"}
        """
        let answer = try LiveAssistAnswerParser.parse(json, providerLabel: "Fake")
        #expect(answer.answer == "Yes, Friday is confirmed.")
        #expect(answer.knownFromMeeting == ["Friday is confirmed"])
        #expect(answer.confidence == "high")
        #expect(answer.providerLabel == "Fake")
    }

    @Test func parsesAnAnswerWrappedInCodeFences() throws {
        let json = """
        ```json
        {"answer": "Not enough information.", "known_from_meeting": [], "from_context": [],
         "assumptions": ["Meeting may have discussed this before this session started"], "confidence": "low"}
        ```
        """
        let answer = try LiveAssistAnswerParser.parse(json, providerLabel: "Fake")
        #expect(answer.answer == "Not enough information.")
        #expect(answer.assumptions.count == 1)
    }

    @Test func missingConfidenceDefaultsToLow() throws {
        let json = #"{"answer": "Sure.", "known_from_meeting": [], "from_context": [], "assumptions": []}"#
        let answer = try LiveAssistAnswerParser.parse(json, providerLabel: "Fake")
        #expect(answer.confidence == "low")
    }

    @Test func missingArraysDefaultToEmptyNotAnError() throws {
        let json = #"{"answer": "Sure.", "confidence": "medium"}"#
        let answer = try LiveAssistAnswerParser.parse(json, providerLabel: "Fake")
        #expect(answer.knownFromMeeting.isEmpty)
        #expect(answer.fromContext.isEmpty)
        #expect(answer.assumptions.isEmpty)
    }

    @Test func emptyAnswerFieldThrows() {
        let json = #"{"answer": "", "known_from_meeting": [], "from_context": [], "assumptions": [], "confidence": "low"}"#
        #expect(throws: LiveAssistAnswerParseError.self) { _ = try LiveAssistAnswerParser.parse(json, providerLabel: "Fake") }
    }

    @Test func malformedInputThrowsAndNeverCrashes() {
        for bad in ["not json at all", "", "{unterminated"] {
            #expect(throws: LiveAssistAnswerParseError.self) { _ = try LiveAssistAnswerParser.parse(bad, providerLabel: "Fake") }
        }
    }
}

// MARK: - Post-check (plan §7.1: unsupported "known" claim → assumptions)

@Suite struct LiveAssistAnswerPostCheckTests {
    private func answer(known: [String], assumptions: [String] = []) -> LiveAssistAnswer {
        LiveAssistAnswer(answer: "x", knownFromMeeting: known, fromContext: [], assumptions: assumptions,
                        confidence: "high", providerLabel: "Fake")
    }

    @Test func claimWithNoTokenOverlapMovesToAssumptions() {
        let checked = LiveAssistAnswerPostCheck.apply(
            answer(known: ["Alice owns the ERP migration"]),
            evidencePool: "We talked about the budget and the marketing plan.")
        #expect(checked.knownFromMeeting.isEmpty)
        #expect(checked.assumptions == ["Alice owns the ERP migration"])
    }

    @Test func claimWithTokenOverlapStaysKnown() {
        let checked = LiveAssistAnswerPostCheck.apply(
            answer(known: ["Deadline is fixed"]),
            evidencePool: "Do we have a fixed deadline for this release?")
        #expect(checked.knownFromMeeting == ["Deadline is fixed"])
        #expect(checked.assumptions.isEmpty)
    }

    @Test func existingAssumptionsAreNeverDropped() {
        let checked = LiveAssistAnswerPostCheck.apply(
            answer(known: ["Unrelated claim"], assumptions: ["Already an assumption"]),
            evidencePool: "Something completely different was discussed.")
        #expect(checked.assumptions.contains("Already an assumption"))
        #expect(checked.assumptions.contains("Unrelated claim"))
    }

    @Test func emptyKnownFromMeetingIsANoOp() {
        let checked = LiveAssistAnswerPostCheck.apply(answer(known: []), evidencePool: "anything")
        #expect(checked.knownFromMeeting.isEmpty)
        #expect(checked.assumptions.isEmpty)
    }

    @Test func fromContextClaimsAreNeverChecked() {
        var a = answer(known: [])
        a.fromContext = ["Something only the context file said"]
        let checked = LiveAssistAnswerPostCheck.apply(a, evidencePool: "totally unrelated meeting content")
        #expect(checked.fromContext == ["Something only the context file said"])
    }
}

// MARK: - Manual project context (plan §7.3)

@Suite struct ManualFileContextProviderTests {
    @Test func shortTextIsNotTruncated() throws {
        let provider = try ManualFileContextProvider(fileName: "notes.md", rawText: "Short content.", maxChars: 100)
        #expect(provider.text == "Short content.")
        #expect(!provider.truncated)
    }

    @Test func longTextIsCappedAndFlaggedTruncated() throws {
        let long = String(repeating: "x", count: 500)
        let provider = try ManualFileContextProvider(fileName: "notes.md", rawText: long, maxChars: 100)
        #expect(provider.text.count == 100)
        #expect(provider.truncated)
    }

    @Test func snippetsReturnsOneSnippetNamedAfterTheFile() async throws {
        let provider = try ManualFileContextProvider(fileName: "roadmap.md", rawText: "Q3 target.", maxChars: 1_000)
        let snippets = try await provider.snippets(forQuestion: "anything")
        #expect(snippets.count == 1)
        #expect(snippets[0].source == "roadmap.md")
        #expect(snippets[0].text == "Q3 target.")
    }

    @Test func readsARealFileFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetgist-context-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("plan.md")
        try "Ship date is October.".write(to: fileURL, atomically: true, encoding: .utf8)

        let provider = try ManualFileContextProvider(fileURL: fileURL)
        #expect(provider.fileName == "plan.md")
        #expect(provider.text == "Ship date is October.")
        #expect(!provider.truncated)
    }

    @Test func zeroOrNegativeCapThrows() {
        #expect(throws: PipelineError.self) {
            _ = try ManualFileContextProvider(fileName: "f.md", rawText: "x", maxChars: 0)
        }
    }
}

// MARK: - Schema strict-mode validation (plan: "add a unit test that
// validates every schema you add against those rules" — P4 found a real
// HTTP 400 from a schema missing this).

@Suite struct LiveCopilotSchemaStrictModeTests {
    /// Recursively checks OpenAI's structured-output "strict mode"
    /// requirements: every `"type": "object"` node must have
    /// `"additionalProperties": false`, and every key under `properties`
    /// must also appear in `required`. Walks into `properties` values and
    /// `items` (array element schemas) so a schema with nested objects
    /// (like `semanticJSONSchema`'s `decisions`/`action_items`) is fully
    /// covered, not just the top level.
    private func assertStrictMode(_ schemaText: String, label: String) throws {
        let data = try #require(schemaText.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try walk(root, path: label)
    }

    private func walk(_ node: [String: Any], path: String) throws {
        if (node["type"] as? String) == "object" {
            #expect((node["additionalProperties"] as? Bool) == false, "\(path): object must have additionalProperties: false")
            let properties = (node["properties"] as? [String: Any]) ?? [:]
            let required = Set((node["required"] as? [Any])?.compactMap { $0 as? String } ?? [])
            for key in properties.keys {
                #expect(required.contains(key), "\(path): property \"\(key)\" must be listed in required")
            }
            for (key, value) in properties {
                if let sub = value as? [String: Any] { try walk(sub, path: "\(path).\(key)") }
            }
        }
        if let items = node["items"] as? [String: Any] {
            try walk(items, path: "\(path)[]")
        }
    }

    @Test func semanticJSONSchemaSatisfiesStrictMode() throws {
        try assertStrictMode(LiveCopilotPrompts.semanticJSONSchema, label: "semanticJSONSchema")
    }

    @Test func answerJSONSchemaSatisfiesStrictMode() throws {
        try assertStrictMode(LiveCopilotPrompts.answerJSONSchema, label: "answerJSONSchema")
    }
}
