// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// MARK: - V2 (Suggested Answer / Ask Meet Gist) — plan §7

/// Which V2 flow produced/is producing an answer. Both flows share one
/// output shape and one engine scheduling slot (plan §7 "Scheduling"): at
/// most one V2 request in flight, a new one cancels the old, regardless of
/// which kind it is.
public enum LiveAssistV2Kind: String, Sendable, Equatable, Codable {
    case suggestAnswer = "suggest_answer"
    case ask
}

/// The known/inferred answer shape shared by Suggest Answer (plan §7.1) and
/// Ask Meet Gist (plan §7.2). `knownFromMeeting` is claims the model says are
/// grounded in the transcript/state; `fromContext` is claims grounded in the
/// user's manually selected file; `assumptions` is everything else/inferred.
/// The engine's post-check (`LiveAssistAnswerPostCheck`) moves an
/// unsupported `knownFromMeeting` claim into `assumptions` before this is
/// ever published — a conformer/parser never needs to re-check that itself.
public struct LiveAssistAnswer: Sendable, Equatable, Codable {
    public var answer: String
    public var knownFromMeeting: [String]
    public var fromContext: [String]
    public var assumptions: [String]
    /// "high" | "medium" | "low" — free string (not an enum) since the
    /// schema's `enum` constraint already limits what a well-behaved
    /// provider sends, and an unexpected value should still round-trip
    /// rather than error.
    public var confidence: String
    public var providerLabel: String

    public init(answer: String, knownFromMeeting: [String], fromContext: [String],
                assumptions: [String], confidence: String, providerLabel: String) {
        self.answer = answer
        self.knownFromMeeting = knownFromMeeting
        self.fromContext = fromContext
        self.assumptions = assumptions
        self.confidence = confidence
        self.providerLabel = providerLabel
    }
}

/// One entry in the panel's bounded Ask Meet Gist history (plan §7.2: "keep
/// only the last 5 Q&A in memory for the panel"). Not persisted verbatim as
/// this type — `LiveCopilotPersistence.appendAssist` writes the equivalent
/// fields to `live/assist.jsonl` as they're produced.
public struct LiveAssistQAEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: LiveAssistV2Kind
    public let question: String
    public let answer: LiveAssistAnswer
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: LiveAssistV2Kind, question: String,
                answer: LiveAssistAnswer, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }
}

/// One `live/assist.jsonl` line (plan §5.13/§7.2/§7.3) — question, answer,
/// provider, latency, and the context file's **name only**, never its
/// content. Written by `LiveCopilotPersistence.appendAssist` after every
/// completed (non-stale, non-cancelled) V2 request.
public struct LiveAssistAssistLogEntry: Codable, Sendable, Equatable {
    public var kind: String   // LiveAssistV2Kind.rawValue
    public var question: String
    public var answer: String
    public var provider: String
    public var latencySeconds: Double
    public var contextFileName: String?
    public var confidence: String

    public init(kind: LiveAssistV2Kind, question: String, answer: String, provider: String,
                latencySeconds: Double, contextFileName: String?, confidence: String) {
        self.kind = kind.rawValue
        self.question = question
        self.answer = answer
        self.provider = provider
        self.latencySeconds = latencySeconds
        self.contextFileName = contextFileName
        self.confidence = confidence
    }
}

public enum LiveAssistAnswerParseError: Error, Sendable, Equatable, LocalizedError {
    case malformed(String)
    public var errorDescription: String? {
        switch self { case .malformed(let reason): return "Malformed answer response: \(reason)" }
    }
}

/// Tolerant decode of `LiveCopilotPrompts.answerJSONSchema` (plan §7.1/§7.2)
/// — same tolerance policy as `SemanticResultParser`: missing arrays become
/// empty, an unrecognized `confidence` is passed through as-is (the UI just
/// shows whatever string it got), and only genuinely non-JSON input throws.
public enum LiveAssistAnswerParser {
    public static func parse(_ raw: String, providerLabel: String) throws -> LiveAssistAnswer {
        let stripped = SemanticResultParser.stripCodeFences(raw)
        guard let objectText = SemanticResultParser.outermostObject(stripped) else {
            throw LiveAssistAnswerParseError.malformed("no JSON object found in response")
        }
        guard let data = objectText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LiveAssistAnswerParseError.malformed("response is not a valid JSON object")
        }
        func string(_ key: String) -> String { (obj[key] as? String) ?? "" }
        func stringArray(_ key: String) -> [String] { (obj[key] as? [Any])?.compactMap { $0 as? String } ?? [] }

        let answer = string("answer")
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveAssistAnswerParseError.malformed("empty \"answer\" field")
        }
        return LiveAssistAnswer(
            answer: answer, knownFromMeeting: stringArray("known_from_meeting"),
            fromContext: stringArray("from_context"), assumptions: stringArray("assumptions"),
            confidence: string("confidence").isEmpty ? "low" : string("confidence"),
            providerLabel: providerLabel)
    }
}

/// Post-check (plan §7.1): "Unsupported claims must go to assumptions;
/// post-check: an item in `known_from_meeting` that has no token overlap
/// with turns/state is moved to `assumptions`." Deliberately independent of
/// the LLM — a deterministic guard, same spirit as `LiveMeetingState`'s
/// evidence guards. `fromContext` claims are not checked here: they're
/// grounded in the user's own selected file, which this guard doesn't see
/// (and isn't asked to validate against).
public enum LiveAssistAnswerPostCheck {
    public static func apply(_ answer: LiveAssistAnswer, evidencePool: String) -> LiveAssistAnswer {
        guard !answer.knownFromMeeting.isEmpty else { return answer }
        let poolTokens = Set(LiveTextNormalize.tokens(evidencePool))
        var known: [String] = []
        var assumptions = answer.assumptions
        for claim in answer.knownFromMeeting {
            let claimTokens = LiveTextNormalize.tokens(claim)
            let hasOverlap = !claimTokens.isEmpty && claimTokens.contains { poolTokens.contains($0) }
            if hasOverlap { known.append(claim) } else { assumptions.append(claim) }
        }
        var result = answer
        result.knownFromMeeting = known
        result.assumptions = assumptions
        return result
    }
}
