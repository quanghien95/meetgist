// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One line of `live/metrics.jsonl` (plan §5.9). `timings` mirrors
/// `LiveTurnTimings`; everything else is provider/size/timing bookkeeping —
/// never prompt or response content.
public struct LiveMetricEntry: Codable, Sendable, Equatable {
    public var turnIDs: [Int]
    public var track: LiveTrack?
    public var timings: LiveTurnTimings
    public var providerLabel: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var llmLatencySeconds: Double?
    public var skippedReason: String?
    public var failed: Bool
    /// Set only for a V2 (Suggest Answer / Ask Meet Gist) entry — plan §7's
    /// "suggest_pressed → answer_visible" / "ask_submitted → answer_visible"
    /// metric, one entry per completed (success or failure) V2 request.
    /// `nil` for every V1 (per-turn semantic) entry.
    public var v2Kind: String?

    public init(turnIDs: [Int], track: LiveTrack? = nil, timings: LiveTurnTimings = LiveTurnTimings(),
                providerLabel: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                llmLatencySeconds: Double? = nil, skippedReason: String? = nil, failed: Bool = false,
                v2Kind: String? = nil) {
        self.turnIDs = turnIDs
        self.track = track
        self.timings = timings
        self.providerLabel = providerLabel
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.llmLatencySeconds = llmLatencySeconds
        self.skippedReason = skippedReason
        self.failed = failed
        self.v2Kind = v2Kind
    }
}

public struct LiveMetricsSummary: Codable, Sendable, Equatable {
    public var requestCountByProvider: [String: Int]
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var llmLatencyP50Seconds: Double?
    public var llmLatencyP90Seconds: Double?
    public var skippedCount: Int
    public var failedCount: Int
    public var malformedCount: Int
    /// Filled in by the app side once the ASR worker reports its own
    /// numbers (`ready` message) — engine-level metrics don't have these.
    public var asrWorkerLoadMs: Double?
    public var asrWorkerPeakMemoryMB: Double?

    // MARK: - V2 (plan §7 "Metrics")
    public var suggestAnswerCount: Int
    public var suggestAnswerLatencyP50Seconds: Double?
    public var suggestAnswerLatencyP90Seconds: Double?
    public var askCount: Int
    public var askLatencyP50Seconds: Double?
    public var askLatencyP90Seconds: Double?
    public var v2RequestCountByProvider: [String: Int]
    public var v2FailedCount: Int

    public init(requestCountByProvider: [String: Int] = [:], totalInputTokens: Int = 0, totalOutputTokens: Int = 0,
                llmLatencyP50Seconds: Double? = nil, llmLatencyP90Seconds: Double? = nil,
                skippedCount: Int = 0, failedCount: Int = 0, malformedCount: Int = 0,
                asrWorkerLoadMs: Double? = nil, asrWorkerPeakMemoryMB: Double? = nil,
                suggestAnswerCount: Int = 0, suggestAnswerLatencyP50Seconds: Double? = nil,
                suggestAnswerLatencyP90Seconds: Double? = nil, askCount: Int = 0,
                askLatencyP50Seconds: Double? = nil, askLatencyP90Seconds: Double? = nil,
                v2RequestCountByProvider: [String: Int] = [:], v2FailedCount: Int = 0) {
        self.requestCountByProvider = requestCountByProvider
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.llmLatencyP50Seconds = llmLatencyP50Seconds
        self.llmLatencyP90Seconds = llmLatencyP90Seconds
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.malformedCount = malformedCount
        self.asrWorkerLoadMs = asrWorkerLoadMs
        self.asrWorkerPeakMemoryMB = asrWorkerPeakMemoryMB
        self.suggestAnswerCount = suggestAnswerCount
        self.suggestAnswerLatencyP50Seconds = suggestAnswerLatencyP50Seconds
        self.suggestAnswerLatencyP90Seconds = suggestAnswerLatencyP90Seconds
        self.askCount = askCount
        self.askLatencyP50Seconds = askLatencyP50Seconds
        self.askLatencyP90Seconds = askLatencyP90Seconds
        self.v2RequestCountByProvider = v2RequestCountByProvider
        self.v2FailedCount = v2FailedCount
    }
}

/// Accumulates per-turn timing/usage entries for one recording and derives
/// the session summary (plan §5.9). A plain value type — `LiveCopilotEngine`
/// (an actor) is the only owner of any instance, so no extra synchronization
/// is needed here.
public struct LiveMetrics: Sendable {
    public private(set) var entries: [LiveMetricEntry] = []
    private var malformedCount = 0

    public init() {}

    public mutating func recordSkipped(turnID: Int, track: LiveTrack, reason: String) {
        entries.append(LiveMetricEntry(turnIDs: [turnID], track: track, skippedReason: reason))
    }

    public mutating func recordLLMSuccess(turnIDs: [Int], providerLabel: String, inputTokens: Int?,
                                          outputTokens: Int?, latencySeconds: Double) {
        entries.append(LiveMetricEntry(turnIDs: turnIDs, providerLabel: providerLabel,
                                       inputTokens: inputTokens, outputTokens: outputTokens,
                                       llmLatencySeconds: latencySeconds))
    }

    public mutating func recordLLMFailure(turnIDs: [Int], providerLabel: String) {
        entries.append(LiveMetricEntry(turnIDs: turnIDs, providerLabel: providerLabel, failed: true))
    }

    public mutating func recordMalformed() { malformedCount += 1 }

    /// A dedicated metrics line stamping when the app actually rendered the
    /// snapshot reflecting `turnID` (plan §5.9: "`ui_update` is stamped by
    /// the app when the snapshot is rendered" — this actor/value type never
    /// stamps it itself). Kept as its own entry rather than mutating an
    /// existing one so `metrics.jsonl` stays a simple append-only log.
    public mutating func recordUIUpdate(turnID: Int, atHostNs: UInt64) {
        entries.append(LiveMetricEntry(turnIDs: [turnID], timings: LiveTurnTimings(uiUpdateHostNs: atHostNs)))
    }

    // MARK: - V2 (plan §7 "Metrics": suggest_pressed → answer_visible,
    // ask_submitted → answer_visible, per provider). `latencySeconds` is the
    // engine-observed request→response latency (the LLM call itself, same
    // basis as V1's `llmLatencySeconds`) — the closest bound this actor/value
    // type has on "pressed/submitted → answer visible" without the app's own
    // UI-render timestamp (which, like V1's `ui_update`, would need its own
    // stamped entry from the app side if ever added).
    public mutating func recordV2Success(kind: LiveAssistV2Kind, providerLabel: String,
                                         inputTokens: Int?, outputTokens: Int?, latencySeconds: Double) {
        entries.append(LiveMetricEntry(turnIDs: [], providerLabel: providerLabel, inputTokens: inputTokens,
                                       outputTokens: outputTokens, llmLatencySeconds: latencySeconds,
                                       v2Kind: kind.rawValue))
    }

    public mutating func recordV2Failure(kind: LiveAssistV2Kind, providerLabel: String) {
        entries.append(LiveMetricEntry(turnIDs: [], providerLabel: providerLabel, failed: true, v2Kind: kind.rawValue))
    }

    public func summary() -> LiveMetricsSummary {
        var counts: [String: Int] = [:]
        var totalIn = 0, totalOut = 0
        var latencies: [Double] = []
        var skipped = 0, failed = 0
        var v2Counts: [String: Int] = [:]
        var v2Failed = 0
        var suggestLatencies: [Double] = [], askLatencies: [Double] = []
        var suggestCount = 0, askCount = 0
        for entry in entries {
            guard entry.v2Kind == nil else {
                if let provider = entry.providerLabel { v2Counts[provider, default: 0] += 1 }
                if entry.failed { v2Failed += 1 }
                switch entry.v2Kind {
                case LiveAssistV2Kind.suggestAnswer.rawValue:
                    suggestCount += 1
                    if let latency = entry.llmLatencySeconds { suggestLatencies.append(latency) }
                case LiveAssistV2Kind.ask.rawValue:
                    askCount += 1
                    if let latency = entry.llmLatencySeconds { askLatencies.append(latency) }
                default: break
                }
                continue
            }
            if let provider = entry.providerLabel { counts[provider, default: 0] += 1 }
            totalIn += entry.inputTokens ?? 0
            totalOut += entry.outputTokens ?? 0
            if let latency = entry.llmLatencySeconds { latencies.append(latency) }
            if entry.skippedReason != nil { skipped += 1 }
            if entry.failed { failed += 1 }
        }
        let sorted = latencies.sorted()
        return LiveMetricsSummary(
            requestCountByProvider: counts, totalInputTokens: totalIn, totalOutputTokens: totalOut,
            llmLatencyP50Seconds: percentile(sorted, 0.50), llmLatencyP90Seconds: percentile(sorted, 0.90),
            skippedCount: skipped, failedCount: failed, malformedCount: malformedCount,
            suggestAnswerCount: suggestCount,
            suggestAnswerLatencyP50Seconds: percentile(suggestLatencies.sorted(), 0.50),
            suggestAnswerLatencyP90Seconds: percentile(suggestLatencies.sorted(), 0.90),
            askCount: askCount,
            askLatencyP50Seconds: percentile(askLatencies.sorted(), 0.50),
            askLatencyP90Seconds: percentile(askLatencies.sorted(), 0.90),
            v2RequestCountByProvider: v2Counts, v2FailedCount: v2Failed)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.down))))
        return sorted[index]
    }

    /// One JSON-lines-formatted line per entry not yet flushed, starting
    /// from `alreadyFlushed`. Callers pass the running flushed count so the
    /// same `LiveMetrics` value can be flushed incrementally.
    public func jsonLines(from alreadyFlushed: Int) -> Data {
        var out = Data()
        let encoder = JSONEncoder()
        for entry in entries.dropFirst(alreadyFlushed) {
            guard let line = try? encoder.encode(entry) else { continue }
            out.append(line)
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    public func summaryJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(summary())
    }
}
