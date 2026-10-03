// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Classification of the latest analyzed turn (plan §5.6). `isQuestion` is
/// true only for `.question`/`.request` that still needs an answer — a
/// rhetorical or self-answered question is not something the user needs to
/// respond to.
public enum LiveSpeechAct: String, Codable, Sendable, Equatable {
    case question
    case request
    case rhetoricalQuestion = "rhetorical_question"
    case selfAnsweredQuestion = "self_answered_question"
    case statement
    case filler
}

public struct SemanticDecision: Sendable, Equatable {
    public var text: String
    /// Short verbatim quote from the turns that grounds this decision —
    /// `LiveMeetingState` drops any decision whose evidence it can't find.
    public var evidence: String

    public init(text: String, evidence: String) {
        self.text = text
        self.evidence = evidence
    }
}

public struct SemanticActionItem: Sendable, Equatable {
    public var text: String
    public var owner: String?
    public var deadline: String?
    public var evidence: String

    public init(text: String, owner: String?, deadline: String?, evidence: String) {
        self.text = text
        self.owner = owner
        self.deadline = deadline
        self.evidence = evidence
    }
}

/// Tolerant decode of `LiveCopilotPrompts`'s JSON schema (plan §5.6). Never
/// throws for a merely-incomplete document — missing arrays become empty,
/// an unrecognized `speech_act` becomes `.statement` — only for input that
/// isn't a JSON object at all.
public struct SemanticResult: Sendable, Equatable {
    public var meaning: String
    public var speechAct: LiveSpeechAct
    public var isQuestion: Bool
    public var question: String
    public var topic: String
    public var keyPoints: [String]
    public var decisions: [SemanticDecision]
    public var actionItems: [SemanticActionItem]
    public var openQuestions: [String]
    public var resolvedOpenQuestionIDs: [String]

    public init(meaning: String = "", speechAct: LiveSpeechAct = .statement, isQuestion: Bool = false,
                question: String = "", topic: String = "", keyPoints: [String] = [],
                decisions: [SemanticDecision] = [], actionItems: [SemanticActionItem] = [],
                openQuestions: [String] = [], resolvedOpenQuestionIDs: [String] = []) {
        self.meaning = meaning
        self.speechAct = speechAct
        self.isQuestion = isQuestion
        self.question = question
        self.topic = topic
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.resolvedOpenQuestionIDs = resolvedOpenQuestionIDs
    }
}

public enum SemanticParseError: Error, Sendable, Equatable, LocalizedError {
    case malformed(String)
    public var errorDescription: String? {
        switch self { case .malformed(let reason): return "Malformed semantic response: \(reason)" }
    }
}

public enum SemanticResultParser {
    /// Strips code fences, takes the outermost `{…}`, decodes tolerantly.
    /// Throws `SemanticParseError.malformed` only when no JSON object at all
    /// can be recovered from `raw` — a `malformed` result must never mutate
    /// `LiveMeetingState` (plan §5.6/§5.14).
    public static func parse(_ raw: String) throws -> SemanticResult {
        let stripped = stripCodeFences(raw)
        guard let objectText = outermostObject(stripped) else {
            throw SemanticParseError.malformed("no JSON object found in response")
        }
        guard let data = objectText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SemanticParseError.malformed("response is not a valid JSON object")
        }

        func string(_ key: String) -> String { (obj[key] as? String) ?? "" }
        func stringArray(_ key: String) -> [String] {
            (obj[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }

        let speechAct = LiveSpeechAct(rawValue: string("speech_act")) ?? .statement
        let decisions: [SemanticDecision] = ((obj["decisions"] as? [Any]) ?? []).compactMap { entry in
            guard let dict = entry as? [String: Any], let text = dict["text"] as? String, !text.isEmpty else { return nil }
            return SemanticDecision(text: text, evidence: (dict["evidence"] as? String) ?? "")
        }
        let actionItems: [SemanticActionItem] = ((obj["action_items"] as? [Any]) ?? []).compactMap { entry in
            guard let dict = entry as? [String: Any], let text = dict["text"] as? String, !text.isEmpty else { return nil }
            return SemanticActionItem(text: text, owner: dict["owner"] as? String, deadline: dict["deadline"] as? String,
                                      evidence: (dict["evidence"] as? String) ?? "")
        }
        let isQuestion = (obj["is_question"] as? Bool) ?? (speechAct == .question || speechAct == .request)

        return SemanticResult(
            meaning: string("meaning"), speechAct: speechAct, isQuestion: isQuestion,
            question: string("question"), topic: string("topic"),
            keyPoints: stringArray("key_points"), decisions: decisions, actionItems: actionItems,
            openQuestions: stringArray("open_questions"), resolvedOpenQuestionIDs: stringArray("resolved_open_question_ids"))
    }

    static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        } else {
            t = String(t.dropFirst(3))
        }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func outermostObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}
