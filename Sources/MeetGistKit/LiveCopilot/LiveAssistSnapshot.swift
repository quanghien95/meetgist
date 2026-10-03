// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct LiveAssistActionItemView: Sendable, Equatable {
    public let text: String
    public let owner: String?
    public let deadline: String?

    public init(text: String, owner: String?, deadline: String?) {
        self.text = text
        self.owner = owner
        self.deadline = deadline
    }
}

/// Immutable, UI-ready view of the engine's current understanding (plan
/// §5.8/§5.12). `LiveCopilotEngine` publishes one of these after every
/// applied (non-stale, non-cancelled) semantic result, plus on every status
/// change — the app hops to the main actor and renders it directly, never
/// reaching back into engine internals.
public struct LiveAssistSnapshot: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle
        case listening
        case analyzing
        /// Result received but couldn't be parsed — state unchanged; the
        /// snapshot content besides `status` still reflects the last good
        /// result (plan §5.6/§5.14: malformed = ignored, no state change).
        case malformedResponse
        case providerUnavailableRetrying
        case codexUnavailable
        case liveTranscriptionUnavailable
        case chooseCloudProvider
        /// The Live ASR runtime isn't installed (plan §5.4/§5.14) — distinct
        /// from `liveTranscriptionUnavailable` (worker crash/timeout after it
        /// was running) so the panel can point at Settings specifically.
        /// Set only by `AppState+LiveAssist.swift` (P3), never by this Kit.
        case liveASRNotInstalled
    }

    public var status: Status
    public var topic: String
    public var lastMeaning: String?
    public var lastQuestionID: String?
    public var lastQuestion: String?
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [LiveAssistActionItemView]
    public var openQuestionCount: Int
    public var latestTranscriptTurn: LiveTranscriptTurn?
    /// Finalized turns retained for reading in the current live session.
    /// Separate from the bounded context sent to semantic/answer providers.
    public var transcriptTurns: [LiveTranscriptTurn]
    /// Mirrors `LiveMeetingState.version` at the time this snapshot was built.
    public var version: Int

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7
    /// True while a V2 request (either kind) is in flight — the UI's
    /// "in-progress" state (user priority: "show an in-progress state for
    /// the answer" — Codex CLI is ~7s p50, never leave the panel looking
    /// stuck with no feedback).
    public var v2AnswerInFlight: Bool
    /// Which flow `v2Answer` (or the in-flight request) belongs to.
    public var v2Kind: LiveAssistV2Kind?
    /// The question `v2Answer` (or the in-flight request) is answering.
    public var v2Question: String?
    /// Latest completed V2 answer (Suggest Answer or Ask), if any — the
    /// panel's single "answer area" shows whichever ran most recently.
    public var v2Answer: LiveAssistAnswer?
    /// User-facing message when a V2 request fails (provider unavailable,
    /// timeout, malformed output) — cleared by the next request.
    public var v2Error: String?
    /// Bounded to the last 5 (plan §7.2) — Ask Meet Gist only; Suggest
    /// Answer's result lives only in `v2Answer`, not in this history.
    public var v2AskHistory: [LiveAssistQAEntry]

    public init(status: Status = .idle, topic: String = "", lastMeaning: String? = nil,
                lastQuestionID: String? = nil, lastQuestion: String? = nil,
                keyPoints: [String] = [], decisions: [String] = [],
                actionItems: [LiveAssistActionItemView] = [], openQuestionCount: Int = 0,
                latestTranscriptTurn: LiveTranscriptTurn? = nil, transcriptTurns: [LiveTranscriptTurn] = [], version: Int = 0,
                v2AnswerInFlight: Bool = false, v2Kind: LiveAssistV2Kind? = nil, v2Question: String? = nil,
                v2Answer: LiveAssistAnswer? = nil, v2Error: String? = nil,
                v2AskHistory: [LiveAssistQAEntry] = []) {
        self.status = status
        self.topic = topic
        self.lastMeaning = lastMeaning
        self.lastQuestionID = lastQuestionID
        self.lastQuestion = lastQuestion
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestionCount = openQuestionCount
        self.latestTranscriptTurn = latestTranscriptTurn
        self.transcriptTurns = transcriptTurns
        self.version = version
        self.v2AnswerInFlight = v2AnswerInFlight
        self.v2Kind = v2Kind
        self.v2Question = v2Question
        self.v2Answer = v2Answer
        self.v2Error = v2Error
        self.v2AskHistory = v2AskHistory
    }

    static func from(_ state: LiveMeetingState, status: Status, latestTurn: LiveTranscriptTurn?,
                     transcriptTurns: [LiveTranscriptTurn] = [], v2: LiveAssistV2State = LiveAssistV2State()) -> LiveAssistSnapshot {
        LiveAssistSnapshot(
            status: status, topic: state.topic, lastMeaning: state.lastMeaning,
            lastQuestionID: state.lastQuestionID, lastQuestion: state.lastQuestion,
            keyPoints: state.keyPoints.suffix(6).map(\.text), decisions: state.decisions.map(\.text),
            actionItems: state.actionItems.map { LiveAssistActionItemView(text: $0.text, owner: $0.owner, deadline: $0.deadline) },
            openQuestionCount: state.openQuestions.filter(\.isOpen).count,
            latestTranscriptTurn: latestTurn, transcriptTurns: transcriptTurns, version: state.version,
            v2AnswerInFlight: v2.isInFlight, v2Kind: v2.kind, v2Question: v2.question,
            v2Answer: v2.answer, v2Error: v2.error, v2AskHistory: v2.askHistory)
    }
}

/// Engine-internal V2 bookkeeping folded into every published snapshot (plan
/// §7). A plain value type owned exclusively by `LiveCopilotEngine`, mirrored
/// into `LiveAssistSnapshot` via `LiveAssistSnapshot.from` — kept separate
/// from `LiveMeetingState` since it's request/UI bookkeeping, not meeting
/// understanding (it never feeds the semantic prompt's STATE).
struct LiveAssistV2State: Sendable, Equatable {
    var isInFlight = false
    var kind: LiveAssistV2Kind?
    var question: String?
    var answer: LiveAssistAnswer?
    var error: String?
    /// Newest last, capped to 5 (plan §7.2).
    var askHistory: [LiveAssistQAEntry] = []
}
