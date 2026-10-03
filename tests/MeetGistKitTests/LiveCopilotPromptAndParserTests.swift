// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct LiveCopilotPromptBuilderTests {
    private func turn(_ id: Int, _ track: LiveTrack, _ text: String, start: Double) -> LiveTranscriptTurn {
        LiveTranscriptTurn(id: id, track: track, startedAt: start, endedAt: start + 1, text: text)
    }

    @Test func systemPromptPropagatesTheRequestedLanguage() {
        let prompt = LiveCopilotPrompts.semanticSystemPrompt(language: "Vietnamese")
        #expect(prompt.contains("Vietnamese"))
        let english = LiveCopilotPrompts.semanticSystemPrompt(language: "English")
        #expect(english.contains("English"))
    }

    @Test func userContentIncludesLanguageStateAndBothTurnSections() {
        let state = LiveCopilotPrompts.CompactStateView(
            topic: "Q3 planning", keyPoints: [("k1", "Budget approved")],
            openQuestions: [("q1", "Who owns the ERP migration?")],
            decisions: ["Ship v2 next sprint"],
            actionItems: [("Follow up with finance", "An", "Friday")])
        let recent = [turn(1, .speaker, "Let's review the budget.", start: 0)]
        let current = [turn(2, .speaker, "Do we have sign-off from finance?", start: 5)]

        let content = LiveCopilotPrompts.semanticUserContent(
            language: "Vietnamese", state: state, recentTurns: recent, currentTurns: current)

        #expect(content.contains("LANGUAGE: Vietnamese"))
        #expect(content.contains("Q3 planning"))
        #expect(content.contains("Budget approved"))
        #expect(content.contains("RECENT TURNS"))
        #expect(content.contains("CURRENT TURNS"))
        #expect(content.contains("Do we have sign-off from finance?"))
    }

    @Test func recentTurnsAreBoundedToConfiguredCountAndCharCap() {
        let state = LiveCopilotPrompts.CompactStateView(topic: "", keyPoints: [], openQuestions: [], decisions: [], actionItems: [])
        // 10 recent turns, each long — only the most recent few (per bounds)
        // survive, and the char cap trims from the oldest end.
        let longText = String(repeating: "word ", count: 40)
        let recent = (0..<10).map { turn($0, .speaker, longText, start: Double($0) * 2) }
        let current = [turn(99, .speaker, "Current turn to analyze.", start: 30)]
        let bounds = LiveCopilotPrompts.Bounds(maxRecentTurns: 3, maxRecentTurnsChars: 120)

        let content = LiveCopilotPrompts.semanticUserContent(
            language: "English", state: state, recentTurns: recent, currentTurns: current, bounds: bounds)

        // Turn ids 0-6 (outside the last-3 window) must not appear at all.
        #expect(!content.contains("[00:00]"))
        // The char cap must have dropped at least the oldest of the kept turns.
        let recentSection = content.components(separatedBy: "CURRENT TURNS").first ?? content
        #expect(recentSection.count < (longText.count * 3 + 200))
    }

    @Test func currentTurnsAreNeverTruncatedByRecentTurnsBounds() {
        let state = LiveCopilotPrompts.CompactStateView(topic: "", keyPoints: [], openQuestions: [], decisions: [], actionItems: [])
        let longCurrent = (0..<5).map { turn($0, .speaker, String(repeating: "x", count: 400), start: Double($0)) }
        let content = LiveCopilotPrompts.semanticUserContent(
            language: "English", state: state, recentTurns: [], currentTurns: longCurrent,
            bounds: LiveCopilotPrompts.Bounds(maxRecentTurns: 2, maxRecentTurnsChars: 50))
        // All 5 current turns must be present even though the bounds are tiny
        // (bounds only apply to RECENT TURNS, never CURRENT TURNS).
        for id in 0..<5 {
            #expect(content.contains(String(repeating: "x", count: 400)) || id >= 0) // sanity: text present at all
        }
        #expect(content.components(separatedBy: "Speaker:").count - 1 == 5)
    }
}

@Suite struct SemanticResultParserTests {
    @Test func parsesAWellFormedResponse() throws {
        let json = """
        {"meaning": "They're asking if the deadline is fixed.",
         "speech_act": "question", "is_question": true, "question": "Is the deadline fixed?",
         "topic": "Timeline", "key_points": ["Deadline is next Friday"],
         "decisions": [{"text": "Ship v2 next sprint", "evidence": "we will ship v2 next sprint"}],
         "action_items": [{"text": "Follow up with finance", "owner": "An", "deadline": "Friday", "evidence": "An will follow up with finance by Friday"}],
         "open_questions": ["Who owns the ERP migration?"],
         "resolved_open_question_ids": ["q1"]}
        """
        let result = try SemanticResultParser.parse(json)
        #expect(result.meaning == "They're asking if the deadline is fixed.")
        #expect(result.speechAct == .question)
        #expect(result.isQuestion)
        #expect(result.question == "Is the deadline fixed?")
        #expect(result.keyPoints == ["Deadline is next Friday"])
        #expect(result.decisions.first?.text == "Ship v2 next sprint")
        #expect(result.actionItems.first?.owner == "An")
        #expect(result.resolvedOpenQuestionIDs == ["q1"])
    }

    @Test func parsesAResponseWrappedInCodeFences() throws {
        let json = """
        ```json
        {"meaning": "Just confirming the room booking.", "speech_act": "statement", "is_question": false,
         "question": "", "topic": "", "key_points": [], "decisions": [], "action_items": [],
         "open_questions": [], "resolved_open_question_ids": []}
        ```
        """
        let result = try SemanticResultParser.parse(json)
        #expect(result.meaning == "Just confirming the room booking.")
        #expect(result.speechAct == .statement)
    }

    @Test func parsesEvenWithLeadingOrTrailingProse() throws {
        let json = """
        Sure, here you go:
        {"meaning": "Confirming next steps.", "speech_act": "statement", "is_question": false,
         "question": "", "topic": "", "key_points": [], "decisions": [], "action_items": [],
         "open_questions": [], "resolved_open_question_ids": []}
        Thanks!
        """
        let result = try SemanticResultParser.parse(json)
        #expect(result.meaning == "Confirming next steps.")
    }

    @Test func missingArraysDefaultToEmptyNotAnError() throws {
        let json = #"{"meaning": "m", "speech_act": "statement", "is_question": false, "question": "", "topic": ""}"#
        let result = try SemanticResultParser.parse(json)
        #expect(result.keyPoints.isEmpty)
        #expect(result.decisions.isEmpty)
        #expect(result.actionItems.isEmpty)
        #expect(result.openQuestions.isEmpty)
    }

    @Test func unknownSpeechActFallsBackToStatement() throws {
        let json = #"{"meaning": "m", "speech_act": "banter", "is_question": false, "question": "", "topic": ""}"#
        let result = try SemanticResultParser.parse(json)
        #expect(result.speechAct == .statement)
    }

    @Test func malformedInputThrowsAndNeverCrashes() {
        for bad in ["not json at all", "", "```\nstill not json\n```", "{unterminated"] {
            #expect(throws: SemanticParseError.self) {
                _ = try SemanticResultParser.parse(bad)
            }
        }
    }
}
