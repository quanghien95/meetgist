// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct LiveItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var evidence: String?
    public var createdAtTurnID: Int

    public init(id: String = UUID().uuidString, text: String, evidence: String? = nil, createdAtTurnID: Int) {
        self.id = id
        self.text = text
        self.evidence = evidence
        self.createdAtTurnID = createdAtTurnID
    }
}

public struct LiveActionItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var owner: String?
    public var deadline: String?
    public var evidence: String?
    public var createdAtTurnID: Int

    public init(id: String = UUID().uuidString, text: String, owner: String? = nil, deadline: String? = nil,
                evidence: String? = nil, createdAtTurnID: Int) {
        self.id = id
        self.text = text
        self.owner = owner
        self.deadline = deadline
        self.evidence = evidence
        self.createdAtTurnID = createdAtTurnID
    }
}

public struct LiveQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var isOpen: Bool
    public var createdAtTurnID: Int

    public init(id: String = UUID().uuidString, text: String, isOpen: Bool = true, createdAtTurnID: Int) {
        self.id = id
        self.text = text
        self.isOpen = isOpen
        self.createdAtTurnID = createdAtTurnID
    }
}

/// Incrementally accumulated understanding of the meeting so far (plan
/// §5.7). A pure value type — every rule (dedup, evidence guards, caps) is
/// unit-testable without an engine, an LLM, or I/O. This is deliberately
/// **not** the transcript and never feeds the notes stage; it exists only to
/// give the semantic LLM a compact "what do you already know" context and to
/// drive the Live Assist panel.
public struct LiveMeetingState: Codable, Sendable, Equatable {
    public static let caps = (keyPoints: 40, decisions: 20, actionItems: 30, openQuestions: 15, recentTurns: 8)

    /// Fraction of an evidence quote's normalized tokens that must appear in
    /// the current+recent turn text for a decision/action item to survive
    /// the evidence guard (plan §5.7: "≥ 70% of evidence tokens").
    static let evidenceCoverageThreshold = 0.7
    /// Jaccard threshold used for state-level dedup (looser than the turn
    /// filter's near-identical-utterance threshold, since two paraphrases of
    /// the same fact should still merge).
    static let dedupJaccardThreshold = 0.6

    public var topic: String
    public var keyPoints: [LiveItem]
    public var openQuestions: [LiveQuestion]
    public var decisions: [LiveItem]
    public var actionItems: [LiveActionItem]
    /// Ring buffer, capacity `caps.recentTurns` — kept turns from `ingest`,
    /// independent of what was forwarded to the LLM as context.
    public var recentTurns: [LiveTranscriptTurn]
    public var lastMeaning: String?
    public var lastQuestionID: String?
    public var lastQuestion: String?
    /// Bumped on every `apply`; lets a persistence layer skip a write when
    /// nothing changed.
    public var version: Int
    public var malformedResultCount: Int

    public init() {
        topic = ""
        keyPoints = []
        openQuestions = []
        decisions = []
        actionItems = []
        recentTurns = []
        lastMeaning = nil
        lastQuestionID = nil
        lastQuestion = nil
        version = 0
        malformedResultCount = 0
    }

    /// Appends `turns` to the recent-turns ring buffer and merges a parsed
    /// semantic result into state, applying dedup and the evidence guards.
    /// Called only for a successfully parsed, non-stale response —
    /// `LiveCopilotEngine` is responsible for discarding malformed/stale
    /// results before they ever reach here.
    public mutating func apply(_ result: SemanticResult, forTurns turns: [LiveTranscriptTurn]) {
        version += 1
        let evidencePool = (turns.map(\.text) + recentTurns.suffix(5).map(\.text)).joined(separator: " ")

        if !result.meaning.trimmingCharacters(in: .whitespaces).isEmpty { lastMeaning = result.meaning }
        if result.isQuestion, !result.question.trimmingCharacters(in: .whitespaces).isEmpty {
            lastQuestion = result.question
            lastQuestionID = UUID().uuidString
        }
        if !result.topic.trimmingCharacters(in: .whitespaces).isEmpty { topic = result.topic }

        let latestTurnID = turns.last?.id ?? recentTurns.last?.id ?? 0

        for point in result.keyPoints {
            let text = point.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            mergeUnlessDuplicate(text, into: &keyPoints, evidence: nil, turnID: latestTurnID, cap: Self.caps.keyPoints)
        }

        for question in result.openQuestions {
            let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !openQuestions.contains(where: {
                LiveTextNormalize.isDuplicate($0.text, text, jaccardThreshold: Self.dedupJaccardThreshold)
            }) else { continue }
            openQuestions.append(LiveQuestion(text: text, isOpen: true, createdAtTurnID: latestTurnID))
            trimCapKeepingNewest(&openQuestions, cap: Self.caps.openQuestions)
        }
        for resolvedID in result.resolvedOpenQuestionIDs {
            if let index = openQuestions.firstIndex(where: { $0.id == resolvedID }) {
                openQuestions[index].isOpen = false
            }
        }

        for decision in result.decisions {
            let text = decision.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, evidenceSupported(decision.evidence, in: evidencePool) else { continue }
            mergeUnlessDuplicate(text, into: &decisions, evidence: decision.evidence, turnID: latestTurnID, cap: Self.caps.decisions)
        }

        for item in result.actionItems {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, evidenceSupported(item.evidence, in: evidencePool) else { continue }
            guard !actionItems.contains(where: {
                LiveTextNormalize.isDuplicate($0.text, text, jaccardThreshold: Self.dedupJaccardThreshold)
            }) else { continue }
            var owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let o = owner, o.isEmpty || !LiveTextNormalize.appears(o, in: evidencePool) { owner = nil }
            var deadline = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = deadline, d.isEmpty || !LiveTextNormalize.appears(d, in: evidencePool) { deadline = nil }
            actionItems.append(LiveActionItem(text: text, owner: owner, deadline: deadline,
                                              evidence: item.evidence, createdAtTurnID: latestTurnID))
            trimCapKeepingNewest(&actionItems, cap: Self.caps.actionItems)
        }

        for turn in turns {
            recentTurns.append(turn)
            if recentTurns.count > Self.caps.recentTurns { recentTurns.removeFirst() }
        }
    }

    /// Recorded (but state is left untouched) when the engine fails to parse
    /// a response — a malformed result must never mutate anything else.
    public mutating func recordMalformedResult() { malformedResultCount += 1 }

    // Latency-first default (2026-09-27 decision, plan §3): a smaller
    // compact-state view keeps the semantic prompt short. The plan's
    // original "last 12" is still available by passing `maxKeyPoints:`
    // explicitly.
    public func compactView(maxKeyPoints: Int = 6) -> LiveCopilotPrompts.CompactStateView {
        LiveCopilotPrompts.CompactStateView(
            topic: topic,
            keyPoints: keyPoints.suffix(maxKeyPoints).map { ($0.id, $0.text) },
            openQuestions: openQuestions.filter(\.isOpen).map { ($0.id, $0.text) },
            decisions: decisions.map(\.text),
            actionItems: actionItems.map { ($0.text, $0.owner, $0.deadline) })
    }

    private func evidenceSupported(_ evidence: String, in pool: String) -> Bool {
        let evidenceTokens = LiveTextNormalize.tokens(evidence)
        guard !evidenceTokens.isEmpty else { return false }
        let poolTokens = Set(LiveTextNormalize.tokens(pool))
        let present = evidenceTokens.filter { poolTokens.contains($0) }.count
        return Double(present) / Double(evidenceTokens.count) >= Self.evidenceCoverageThreshold
    }

    private func mergeUnlessDuplicate(_ text: String, into list: inout [LiveItem], evidence: String?,
                                      turnID: Int, cap: Int) {
        guard !list.contains(where: { LiveTextNormalize.isDuplicate($0.text, text, jaccardThreshold: Self.dedupJaccardThreshold) })
        else { return }
        list.append(LiveItem(text: text, evidence: evidence, createdAtTurnID: turnID))
        trimCapKeepingNewest(&list, cap: cap)
    }

    /// Bounds the working-set arrays that back `state.json`/the compact
    /// prompt view, oldest first (plan §5.7's per-category caps). This never
    /// touches `live/turns.jsonl` — the raw per-turn log is append-only and
    /// keeps every turn regardless of these caps.
    private func trimCapKeepingNewest<T>(_ list: inout [T], cap: Int) {
        if list.count > cap { list.removeFirst(list.count - cap) }
    }
}
