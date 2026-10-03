// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Writes the minimal, non-canonical `<session>/live/` artifacts (plan
/// §5.13): `turns.jsonl` (append), `state.json` (atomic, throttled),
/// `metrics.jsonl` (append) + `metrics-summary.json` (atomic). Nothing here
/// is read back for transcription or notes — it exists for the Live Assist
/// panel to resume/inspect and for post-hoc measurement (plan §9). Every
/// instance is owned exclusively by one `LiveCopilotEngine` actor, so this
/// type does its own file I/O synchronously with no internal locking.
public final class LiveCopilotPersistence {
    public let sessionDir: URL
    private let liveDir: URL
    private let fm = FileManager.default
    private var lastStateWriteAt: Date = .distantPast
    private var flushedMetricsCount = 0
    /// Minimum spacing between `state.json` writes (plan §5.13: "throttled
    /// ≤ 1/2 s" — at most two writes per second).
    private let stateWriteMinInterval: TimeInterval = 0.5

    public init?(sessionDir: URL) {
        self.sessionDir = sessionDir
        self.liveDir = sessionDir.appendingPathComponent("live", isDirectory: true)
        do {
            try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
    }

    private var turnsURL: URL { liveDir.appendingPathComponent("turns.jsonl") }
    private var stateURL: URL { liveDir.appendingPathComponent("state.json") }
    private var metricsURL: URL { liveDir.appendingPathComponent("metrics.jsonl") }
    private var metricsSummaryURL: URL { liveDir.appendingPathComponent("metrics-summary.json") }
    private var assistURL: URL { liveDir.appendingPathComponent("assist.jsonl") }
    public var asrWorkerLogURL: URL { liveDir.appendingPathComponent("asr-worker.log") }

    func appendTurn(_ turn: LiveTranscriptTurn) {
        guard let line = try? JSONEncoder().encode(turn) else { return }
        append(line + Data([0x0A]), to: turnsURL)
    }

    /// Reconcile a mic echo that arrived before its system counterpart.
    /// Atomic replacement keeps the saved reading history aligned with UI.
    func replaceTurns(_ turns: [LiveTranscriptTurn]) {
        var data = Data()
        for turn in turns {
            guard let line = try? JSONEncoder().encode(turn) else { return }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: turnsURL, options: .atomic)
    }

    /// Writes `state.json` unless it was written less than
    /// `stateWriteMinInterval` ago and `force` is false.
    func writeState(_ state: LiveMeetingState, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStateWriteAt) >= stateWriteMinInterval else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        atomicWrite(data, to: stateURL)
        lastStateWriteAt = now
    }

    func appendMetrics(_ metrics: LiveMetrics) {
        let data = metrics.jsonLines(from: flushedMetricsCount)
        guard !data.isEmpty else { return }
        append(data, to: metricsURL)
        flushedMetricsCount = metrics.entries.count
    }

    func writeMetricsSummary(_ metrics: LiveMetrics) {
        guard let data = try? metrics.summaryJSON() else { return }
        atomicWrite(data, to: metricsSummaryURL)
    }

    /// One line of `live/assist.jsonl` per completed V2 (Suggest Answer /
    /// Ask Meet Gist) request (plan §5.13/§7.2/§7.3): "question, answer,
    /// provider, latency; context **file name only**, not its content."
    /// `LiveAssistAssistLogEntry` never carries the context file's text —
    /// only `contextFileName` — so this file structurally cannot leak a
    /// selected context file's content, regardless of what the caller passes.
    func appendAssist(_ entry: LiveAssistAssistLogEntry) {
        guard let line = try? JSONEncoder().encode(entry) else { return }
        append(line + Data([0x0A]), to: assistURL)
    }

    private func append(_ data: Data, to url: URL) {
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func atomicWrite(_ data: Data, to url: URL) {
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
        }
    }
}
