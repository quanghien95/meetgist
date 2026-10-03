// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// System prompt, bounded user-content builder, and JSON schema text for the
/// per-turn semantic analysis call (plan §5.6). Kept separate from
/// `LiveCopilotEngine` so the prompt shape is unit-testable without any LLM.
public enum LiveCopilotPrompts {

    /// A bounded, compact projection of `LiveMeetingState` — everything the
    /// prompt needs, nothing else (never the full history).
    public struct CompactStateView: Sendable, Equatable {
        public var topic: String
        public var keyPoints: [(id: String, text: String)]
        public var openQuestions: [(id: String, text: String)]
        public var decisions: [String]
        public var actionItems: [(text: String, owner: String?, deadline: String?)]

        public init(topic: String, keyPoints: [(id: String, text: String)],
                    openQuestions: [(id: String, text: String)], decisions: [String],
                    actionItems: [(text: String, owner: String?, deadline: String?)]) {
            self.topic = topic
            self.keyPoints = keyPoints
            self.openQuestions = openQuestions
            self.decisions = decisions
            self.actionItems = actionItems
        }

        public static func == (lhs: CompactStateView, rhs: CompactStateView) -> Bool {
            lhs.topic == rhs.topic
                && lhs.keyPoints.map(\.id) == rhs.keyPoints.map(\.id)
                && lhs.keyPoints.map(\.text) == rhs.keyPoints.map(\.text)
                && lhs.openQuestions.map(\.id) == rhs.openQuestions.map(\.id)
                && lhs.openQuestions.map(\.text) == rhs.openQuestions.map(\.text)
                && lhs.decisions == rhs.decisions
                && lhs.actionItems.map(\.text) == rhs.actionItems.map(\.text)
                && lhs.actionItems.map(\.owner) == rhs.actionItems.map(\.owner)
                && lhs.actionItems.map(\.deadline) == rhs.actionItems.map(\.deadline)
        }
    }

    /// Bounds applied when rendering `RECENT TURNS`/`CURRENT TURNS`.
    public struct Bounds: Sendable, Equatable {
        public var maxRecentTurns: Int
        public var maxRecentTurnsChars: Int
        // Latency-first defaults (2026-09-27 decision, plan §3): 2-3 recent
        // turns of context, not 5 — keeps the prompt (and therefore the
        // model's time-to-first-token) small.
        public init(maxRecentTurns: Int = 3, maxRecentTurnsChars: Int = 900) {
            self.maxRecentTurns = maxRecentTurns
            self.maxRecentTurnsChars = maxRecentTurnsChars
        }
    }

    // Latency-first (2026-09-27 decision, plan §3): kept short on purpose —
    // fewer instruction tokens means a faster first token, and the
    // post-meeting pipeline is the accuracy backstop, not this prompt.
    public static func semanticSystemPrompt(language: String) -> String {
        """
        Live meeting copilot. For the latest speaker turn(s): state what the \
        speaker MEANS (intent, not literal translation) in \(language), 1 short \
        sentence. Keep terms/names/identifiers/code verbatim.

        speech_act: question|request|rhetorical_question|self_answered_question|statement|filler. \
        is_question=true only if question/request still needs an answer.

        Only NEW facts not already in STATE. Decision/action item only if \
        explicitly stated; never invent owner/deadline/decision — null if unstated. \
        Each decision/action item needs a short verbatim "evidence" quote from TURNS.

        JSON only, matching the schema. No prose, no code fences.
        """
    }

    /// JSON Schema text (plan §5.6) — passed to `CopilotLLMRequest.jsonSchema`
    /// for adapters that support structured output (Gemini/OpenAI JSON mode,
    /// Codex `--output-schema`).
    ///
    /// **Fix (2026-09-27, found by P4's real Codex CLI benchmark run, plan
    /// §9/§13):** every `"type": "object"` schema — the top level and both
    /// array-item schemas — must carry `"additionalProperties": false`, and
    /// every key listed in `properties` must also appear in `required`
    /// (nullable/optional fields are expressed as a `["string", "null"]`
    /// type union instead of being left out of `required`). Without this,
    /// Codex CLI's `--output-schema` (OpenAI's strict structured-output
    /// mode) rejected every semantic request with HTTP 400
    /// `invalid_json_schema` — 12/12 real Codex CLI semantic calls failed
    /// before this fix, 0/12 after. Gemini/`.chat` JSON mode never validated
    /// the schema this strictly and were unaffected either way.
    public static let semanticJSONSchema: String = """
    {
      "type": "object",
      "properties": {
        "meaning": {"type": "string"},
        "speech_act": {"type": "string", "enum": ["question", "request", "rhetorical_question", "self_answered_question", "statement", "filler"]},
        "is_question": {"type": "boolean"},
        "question": {"type": "string"},
        "topic": {"type": "string"},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "object", "properties": {
          "text": {"type": "string"}, "evidence": {"type": "string"}},
          "required": ["text", "evidence"], "additionalProperties": false}},
        "action_items": {"type": "array", "items": {"type": "object", "properties": {
          "text": {"type": "string"}, "owner": {"type": ["string", "null"]},
          "deadline": {"type": ["string", "null"]}, "evidence": {"type": "string"}},
          "required": ["text", "owner", "deadline", "evidence"], "additionalProperties": false}},
        "open_questions": {"type": "array", "items": {"type": "string"}},
        "resolved_open_question_ids": {"type": "array", "items": {"type": "string"}}
      },
      "required": ["meaning", "speech_act", "is_question", "question", "topic",
                   "key_points", "decisions", "action_items", "open_questions",
                   "resolved_open_question_ids"],
      "additionalProperties": false
    }
    """

    /// Bounded user content: `LANGUAGE`, a compact `STATE`, a capped window of
    /// `RECENT TURNS` (context only — never re-analyzed), and the `CURRENT
    /// TURNS` to actually analyze (plan §5.6).
    public static func semanticUserContent(language: String, state: CompactStateView,
                                           recentTurns: [LiveTranscriptTurn],
                                           currentTurns: [LiveTranscriptTurn],
                                           bounds: Bounds = Bounds()) -> String {
        var lines: [String] = []
        lines.append("LANGUAGE: \(language)")
        lines.append("STATE: \(stateJSON(state))")
        lines.append("RECENT TURNS (context, do not re-analyze):")
        lines.append(contentsOf: renderTurns(recentTurns, bounds: bounds))
        lines.append("CURRENT TURNS (analyze these):")
        lines.append(contentsOf: renderTurns(currentTurns, bounds: nil))
        return lines.joined(separator: "\n")
    }

    private static func renderTurns(_ turns: [LiveTranscriptTurn], bounds: Bounds?) -> [String] {
        var kept = turns
        if let bounds { kept = Array(kept.suffix(bounds.maxRecentTurns)) }
        var rendered = kept.map(renderTurn)
        if let bounds {
            var total = rendered.reduce(0) { $0 + $1.count }
            while total > bounds.maxRecentTurnsChars, rendered.count > 1 {
                total -= rendered.removeFirst().count
            }
        }
        return rendered
    }

    private static func renderTurn(_ turn: LiveTranscriptTurn) -> String {
        let label = turn.track == .speaker ? "Speaker" : "Me"
        return "[\(TranscriptText.stamp(turn.startedAt))] \(label): \(turn.text)"
    }

    private static func stateJSON(_ state: CompactStateView) -> String {
        let payload: [String: Any] = [
            "topic": state.topic,
            "key_points": state.keyPoints.map { ["id": $0.id, "text": $0.text] },
            "open_questions": state.openQuestions.map { ["id": $0.id, "text": $0.text] },
            "decisions": state.decisions,
            "action_items": state.actionItems.map {
                ["text": $0.text, "owner": $0.owner as Any? ?? NSNull(), "deadline": $0.deadline as Any? ?? NSNull()]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7

    /// System prompt for both V2 flows — kept as one short prompt (not two)
    /// since they share the exact same output contract; only the user
    /// content differs (a detected question vs. a free-form typed one).
    /// Latency-first (user priority: realtime speed over accuracy) — short,
    /// direct instructions, same spirit as `semanticSystemPrompt`.
    public static func answerSystemPrompt(language: String) -> String {
        """
        You help the user follow a live meeting by answering one question, in \(language), \
        as 1-3 short sentences the user could say out loud right now. Keep terms/names/\
        identifiers/code verbatim.

        Use TURNS and STATE (what was actually said/decided in this meeting) and, if given, \
        CONTEXT (a file the user selected). Separate what you actually know from what you're \
        guessing:
        - known_from_meeting: short facts you used that come from TURNS/STATE.
        - from_context: short facts you used that come from CONTEXT.
        - assumptions: anything inferred, guessed, or not directly stated — never put a \
        guess in known_from_meeting.
        Never invent a fact and call it known. If you don't have enough information, say so \
        in "answer" and keep known_from_meeting/from_context empty rather than guessing.

        JSON only, matching the schema. No prose, no code fences.
        """
    }

    /// JSON Schema text for `{answer, known_from_meeting, from_context,
    /// assumptions, confidence}` (plan §7.1/§7.2), already OpenAI
    /// strict-mode-safe (`additionalProperties: false`, every property in
    /// `required` — see `semanticJSONSchema`'s doc comment for why this
    /// matters: a schema missing either was a real HTTP 400 found in P4).
    /// There's no nested object here (unlike `semanticJSONSchema`'s
    /// `decisions`/`action_items`), so only the top level needs the guard.
    public static let answerJSONSchema: String = """
    {
      "type": "object",
      "properties": {
        "answer": {"type": "string"},
        "known_from_meeting": {"type": "array", "items": {"type": "string"}},
        "from_context": {"type": "array", "items": {"type": "string"}},
        "assumptions": {"type": "array", "items": {"type": "string"}},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]}
      },
      "required": ["answer", "known_from_meeting", "from_context", "assumptions", "confidence"],
      "additionalProperties": false
    }
    """

    /// Bounded user content shared by Suggest Answer and Ask Meet Gist:
    /// `LANGUAGE`, the question being answered, a compact `STATE`, a bounded
    /// `TURNS` window (caller decides the bound — §7.1's "≤8 recent turns"
    /// for Suggest Answer, §7.2's "last 10 minutes, ≤8k chars" for Ask), and
    /// an optional `CONTEXT` section for the manually selected file (plan
    /// §7.3) — omitted entirely when no context was given, so a request
    /// without one costs nothing extra.
    public static func answerUserContent(language: String, question: String, state: CompactStateView,
                                         turns: [LiveTranscriptTurn], context: [ContextSnippet],
                                         bounds: Bounds) -> String {
        var lines: [String] = []
        lines.append("LANGUAGE: \(language)")
        lines.append("QUESTION: \(question)")
        lines.append("STATE: \(stateJSON(state))")
        lines.append("TURNS (bounded, may not cover the whole meeting):")
        lines.append(contentsOf: renderTurns(turns, bounds: bounds))
        if !context.isEmpty {
            lines.append("CONTEXT (user-selected file; may be incomplete):")
            for snippet in context {
                lines.append("[\(snippet.source)]")
                lines.append(snippet.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}
