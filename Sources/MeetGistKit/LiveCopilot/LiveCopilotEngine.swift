// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Schedules semantic analysis of live turns, applies results to
/// `LiveMeetingState`, and publishes `LiveAssistSnapshot`s (plan §5.8). Single
/// owner of all live-copilot mutable state for one recording — `AppState`
/// (P3) only ever calls `ingest`/`setLLM`/`stop` and observes `snapshots()`.
///
/// Scheduling contract (plan §5.8):
/// - At most one semantic request in flight. Turns arriving meanwhile
///   coalesce into a pending batch (bounded to `Config.maxCurrentTurns`);
///   when the in-flight request finishes, the pending batch starts
///   immediately.
/// - Every request gets a strictly increasing `seq`; a response is applied
///   only if `seq > lastAppliedSeq` *and* the engine `generation` captured at
///   request time still matches (`generation` bumps on `stop()`/`setLLM`),
///   so a cancelled/stopped/superseded request never mutates state or
///   publishes.
/// - A timeout cancels the in-flight `Task`, which cancels the underlying
///   HTTP call or (for Codex) kills the subprocess via `ChildProcess`.
/// - 3 consecutive provider failures open a circuit breaker for
///   `circuitBreakerCooldownSeconds`; the next turn after the cooldown tries
///   again.
public actor LiveCopilotEngine {
    public struct Config: Sendable {
        public var language: String
        /// Mic ("Me") turns are always transcribed and kept as context; this
        /// only controls whether they're also sent for semantic analysis
        /// (plan §3: default off — the meaning/question the panel shows is
        /// about *other* participants).
        public var analyzeMic: Bool
        public var maxCurrentTurns: Int
        public var recentTurnsForContext: Int
        public var recentTurnsCharCap: Int
        public var httpSemanticTimeout: TimeInterval
        public var codexSemanticTimeout: TimeInterval
        public var maxOutputTokens: Int
        public var circuitBreakerFailureThreshold: Int
        public var circuitBreakerCooldownSeconds: TimeInterval

        // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7 "Scheduling"
        /// Codex answer/ask 60s start value (plan §7's timeout table);
        /// HTTP (Gemini/chat) answer/ask 20s (plan §5.5, unchanged from the
        /// value scoped in P1/P2 — implemented now in P5).
        public var httpAnswerTimeout: TimeInterval
        public var codexAnswerTimeout: TimeInterval
        public var answerMaxOutputTokens: Int
        /// "≤8 bounded recent turns" for Suggest Answer (plan §7.1).
        public var suggestAnswerMaxRecentTurns: Int
        /// Default 10-minute recent window for Ask Meet Gist (plan §7.2).
        public var askWindowMinutes: Double
        /// ≈8k char cap for Ask Meet Gist's turns window (plan §7.2).
        public var askCharCap: Int

        // Latency-first defaults (2026-09-27 decision, plan §3 "latency
        // first"): tight context and a low output-token budget keep the
        // semantic call fast — the post-meeting pipeline is where accuracy
        // comes from, not this live path.
        public init(language: String = Prompts.defaultNotesLanguage, analyzeMic: Bool = false,
                    maxCurrentTurns: Int = 3, recentTurnsForContext: Int = 3, recentTurnsCharCap: Int = 900,
                    httpSemanticTimeout: TimeInterval = 8, codexSemanticTimeout: TimeInterval = 45,
                    maxOutputTokens: Int = 350, circuitBreakerFailureThreshold: Int = 3,
                    circuitBreakerCooldownSeconds: TimeInterval = 30,
                    httpAnswerTimeout: TimeInterval = 20, codexAnswerTimeout: TimeInterval = 60,
                    answerMaxOutputTokens: Int = 500, suggestAnswerMaxRecentTurns: Int = 8,
                    askWindowMinutes: Double = 10, askCharCap: Int = 8_000) {
            self.language = language
            self.analyzeMic = analyzeMic
            self.maxCurrentTurns = maxCurrentTurns
            self.recentTurnsForContext = recentTurnsForContext
            self.recentTurnsCharCap = recentTurnsCharCap
            self.httpSemanticTimeout = httpSemanticTimeout
            self.codexSemanticTimeout = codexSemanticTimeout
            self.maxOutputTokens = maxOutputTokens
            self.circuitBreakerFailureThreshold = circuitBreakerFailureThreshold
            self.circuitBreakerCooldownSeconds = circuitBreakerCooldownSeconds
            self.httpAnswerTimeout = httpAnswerTimeout
            self.codexAnswerTimeout = codexAnswerTimeout
            self.answerMaxOutputTokens = answerMaxOutputTokens
            self.suggestAnswerMaxRecentTurns = suggestAnswerMaxRecentTurns
            self.askWindowMinutes = askWindowMinutes
            self.askCharCap = askCharCap
        }
    }

    struct TimeoutError: Error {}

    private var config: Config
    private var llm: (any CopilotLLM)?
    private let filter: LiveTurnFilter
    private let persistence: LiveCopilotPersistence?

    private var state = LiveMeetingState()
    private var metrics = LiveMetrics()
    private var pendingBatch: [LiveTranscriptTurn] = []
    private var inFlight = false
    private var inFlightTask: Task<Void, Never>?
    private var nextSeq = 0
    private var lastAppliedSeq = 0
    private var generation = 0
    private var consecutiveFailures = 0
    private var circuitOpenUntil: Date?
    private var status: LiveAssistSnapshot.Status = .idle
    private var latestTurn: LiveTranscriptTurn?
    /// UI-only history for this live session; never used as LLM context.
    private var transcriptTurns: [LiveTranscriptTurn] = []
    private var continuations: [UUID: AsyncStream<LiveAssistSnapshot>.Continuation] = [:]

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7 "Scheduling"
    // Deliberately separate slot/seq/task from the V1 semantic scheduler
    // above: "V2 requests must not share the V1 single-in-flight slot in a
    // way that delays per-turn analysis." `generation` (bumped by
    // `stop()`/`setLLM()`) is shared, so a provider change or stop still
    // invalidates any in-flight V2 request the same way it invalidates V1.
    private var v2State = LiveAssistV2State()
    private var v2InFlightTask: Task<Void, Never>?
    private var v2NextSeq = 0
    private var v2LastAppliedSeq = 0
    /// Every ingested turn (mic + speaker, filtered the same as V1's
    /// `recentTurns`), time-bounded rather than count-bounded so Ask Meet
    /// Gist's "last N minutes" window (plan §7.2) can see more history than
    /// the 8-turn ring buffer `LiveMeetingState.recentTurns` keeps for the
    /// semantic prompt. Capped at `maxAskTurnHistory` turns as a hard memory
    /// ceiling — the per-request time window further narrows what's
    /// actually sent.
    private var askTurnHistory: [LiveTranscriptTurn] = []
    private let maxAskTurnHistory = 200

    public init(config: Config, llm: (any CopilotLLM)?, filter: LiveTurnFilter = LiveTurnFilter(),
                persistence: LiveCopilotPersistence? = nil) {
        self.config = config
        self.llm = llm
        self.filter = filter
        self.persistence = persistence
        self.status = llm == nil ? .chooseCloudProvider : .listening
    }

    // MARK: - Public API (P3 surface)

    /// A live stream of snapshots; the current snapshot is yielded
    /// immediately so a late subscriber (e.g. the panel reopening) doesn't
    /// have to wait for the next turn.
    public func snapshots() -> AsyncStream<LiveAssistSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func currentSnapshot() -> LiveAssistSnapshot {
        LiveAssistSnapshot.from(state, status: status, latestTurn: latestTurn,
                                transcriptTurns: transcriptTurns, v2: v2State)
    }

    public func currentState() -> LiveMeetingState { state }

    // MARK: - P3 seams (called only by `LiveAssistSession`/`AppState+LiveAssist`)

    /// Surfaces an ASR-layer status (runtime missing, worker crashed/timed
    /// out) without touching any other engine state (plan §5.14). This actor
    /// owns no ASR knowledge itself — `LiveAssistSession` calls this when its
    /// `RealtimeTranscriber` fails/recovers. A later applied semantic result
    /// or scheduler tick naturally supersedes this once turns flow again.
    public func setTranscriptionStatus(_ status: LiveAssistSnapshot.Status) {
        updateStatus(status)
    }

    /// Records when the app actually rendered the snapshot reflecting
    /// `turnID` (plan §5.9 — never stamped by this actor itself).
    public func recordUIUpdate(forTurnID turnID: Int, atHostNs: UInt64) {
        metrics.recordUIUpdate(turnID: turnID, atHostNs: atHostNs)
        persistence?.appendMetrics(metrics)
    }

    /// Swaps the LLM (e.g. the user changed the Live Assist provider) and
    /// bumps `generation` so any in-flight request from the old provider can
    /// never apply/publish once it (eventually) completes.
    public func setLLM(_ llm: (any CopilotLLM)?) {
        self.llm = llm
        generation += 1
        inFlightTask?.cancel()
        v2InFlightTask?.cancel()
        v2InFlightTask = nil
        v2State.isInFlight = false
        consecutiveFailures = 0
        circuitOpenUntil = nil
        updateStatus(llm == nil ? .chooseCloudProvider : .listening)
    }

    /// Ends this engine's activity for the recording. Any in-flight request
    /// (V1 or V2) is cancelled and can never publish afterward. Safe to call
    /// more than once and safe to call with no prior `ingest`.
    public func stop() {
        generation += 1
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlight = false
        pendingBatch.removeAll()
        circuitOpenUntil = nil
        v2InFlightTask?.cancel()
        v2InFlightTask = nil
        v2State.isInFlight = false
        persistence?.writeState(state, force: true)
        persistence?.appendMetrics(metrics)
        persistence?.writeMetricsSummary(metrics)
        updateStatus(.idle)
    }

    /// Feeds one finalized turn from a `RealtimeTranscriber`. Filters junk,
    /// keeps context, and (for analyzable turns) schedules/coalesces a
    /// semantic request. Never throws — every failure mode is represented in
    /// `status` instead (plan §5.14).
    public func ingest(_ turn: LiveTranscriptTurn) {
        let recentSameTrack = state.recentTurns.filter { $0.track == turn.track }
        let recentOtherTrack = state.recentTurns.filter { $0.track != turn.track }
        if filter.shouldDrop(turn, recentSameTrack: recentSameTrack, recentOtherTrack: recentOtherTrack) {
            metrics.recordSkipped(turnID: turn.id, track: turn.track, reason: "filtered")
            return
        }

        persistence?.appendTurn(turn)
        state.recentTurns.append(turn)
        if state.recentTurns.count > LiveMeetingState.caps.recentTurns { state.recentTurns.removeFirst() }
        latestTurn = turn
        // Speaker and mic ASR can finish in a different order. Keep the
        // reading timeline ordered by speech time, with stable IDs for ties.
        if let last = transcriptTurns.last,
           last.startedAt > turn.startedAt || (last.startedAt == turn.startedAt && last.id > turn.id) {
            let index = transcriptTurns.firstIndex {
                $0.startedAt > turn.startedAt || ($0.startedAt == turn.startedAt && $0.id > turn.id)
            } ?? transcriptTurns.endIndex
            transcriptTurns.insert(turn, at: index)
        } else {
            transcriptTurns.append(turn)
        }
        askTurnHistory.append(turn)
        if askTurnHistory.count > maxAskTurnHistory { askTurnHistory.removeFirst(askTurnHistory.count - maxAskTurnHistory) }
        persistence?.writeState(state)
        broadcast(currentSnapshot())

        let analyzable = turn.track == .speaker || config.analyzeMic
        guard analyzable else { return }
        pendingBatch.append(turn)
        if pendingBatch.count > config.maxCurrentTurns {
            pendingBatch.removeFirst(pendingBatch.count - config.maxCurrentTurns)
        }
        kickSchedulerIfIdle()
    }

    // MARK: - Scheduling

    private func kickSchedulerIfIdle() {
        guard !inFlight, !pendingBatch.isEmpty else { return }
        if let until = circuitOpenUntil {
            if until > Date() { return }
            circuitOpenUntil = nil
            consecutiveFailures = 0
        }
        guard let llm else {
            updateStatus(.chooseCloudProvider)
            return
        }

        let batch = pendingBatch
        pendingBatch = []
        inFlight = true
        nextSeq += 1
        let seq = nextSeq
        let myGeneration = generation
        let recentContext = recentContextTurns(excluding: batch)
        let compact = state.compactView()
        let request = CopilotLLMRequest(
            system: LiveCopilotPrompts.semanticSystemPrompt(language: config.language),
            user: LiveCopilotPrompts.semanticUserContent(
                language: config.language, state: compact, recentTurns: recentContext, currentTurns: batch,
                bounds: LiveCopilotPrompts.Bounds(maxRecentTurns: config.recentTurnsForContext,
                                                  maxRecentTurnsChars: config.recentTurnsCharCap)),
            jsonSchema: LiveCopilotPrompts.semanticJSONSchema,
            maxOutputTokens: config.maxOutputTokens,
            timeout: llm.providerKind == "codex-cli" ? config.codexSemanticTimeout : config.httpSemanticTimeout,
            purpose: .semantic)

        updateStatus(.analyzing)
        inFlightTask = Task { [weak self] in
            await self?.runSemanticRequest(request, seq: seq, generation: myGeneration, batch: batch, llm: llm)
        }
    }

    private func recentContextTurns(excluding batch: [LiveTranscriptTurn]) -> [LiveTranscriptTurn] {
        let batchIDs = Set(batch.map(\.id))
        return state.recentTurns.filter { !batchIDs.contains($0.id) }
    }

    private func runSemanticRequest(_ request: CopilotLLMRequest, seq: Int, generation: Int,
                                    batch: [LiveTranscriptTurn], llm: any CopilotLLM) async {
        do {
            let response = try await Self.withTimeout(request.timeout) { try await llm.complete(request) }
            applySemanticResponse(response, seq: seq, generation: generation, batch: batch, providerLabel: llm.label)
        } catch {
            handleSemanticFailure(error, seq: seq, generation: generation, batch: batch, providerLabel: llm.label)
        }
    }

    private func applySemanticResponse(_ response: CopilotLLMResponse, seq: Int, generation: Int,
                                       batch: [LiveTranscriptTurn], providerLabel: String) {
        defer { finishInFlight() }
        metrics.recordLLMSuccess(turnIDs: batch.map(\.id), providerLabel: providerLabel,
                                 inputTokens: response.inputTokens, outputTokens: response.outputTokens,
                                 latencySeconds: response.latency)
        consecutiveFailures = 0
        circuitOpenUntil = nil
        guard generation == self.generation else { return }   // stopped/disabled/provider changed meanwhile
        guard seq > lastAppliedSeq else { return }             // superseded by a newer already-applied response

        do {
            let parsed = try SemanticResultParser.parse(response.text)
            lastAppliedSeq = seq
            state.apply(parsed, forTurns: batch)
            persistence?.writeState(state)
            persistence?.appendMetrics(metrics)
            updateStatus(.listening)
        } catch {
            state.recordMalformedResult()
            metrics.recordMalformed()
            updateStatus(.malformedResponse)
        }
    }

    private func handleSemanticFailure(_ error: Error, seq: Int, generation: Int,
                                       batch: [LiveTranscriptTurn], providerLabel: String) {
        defer { finishInFlight() }
        metrics.recordLLMFailure(turnIDs: batch.map(\.id), providerLabel: providerLabel)
        persistence?.appendMetrics(metrics)
        guard generation == self.generation else { return }    // cancelled by stop()/setLLM(): never publish
        if error is CancellationError { return }

        consecutiveFailures += 1
        if consecutiveFailures >= config.circuitBreakerFailureThreshold {
            circuitOpenUntil = Date().addingTimeInterval(config.circuitBreakerCooldownSeconds)
        }
        if case PipelineError.unsupported(let message) = error, message.contains("Codex CLI") {
            updateStatus(.codexUnavailable)
        } else {
            updateStatus(.providerUnavailableRetrying)
        }
    }

    private func finishInFlight() {
        inFlight = false
        inFlightTask = nil
        kickSchedulerIfIdle()
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7

    /// Triggered by the panel's "Suggest Answer" button, or automatically by
    /// `AppState` when `liveAutoSuggest` is on and a new question appears
    /// (plan §7.1). `questionID` must match the *currently* active question
    /// — a press that raced a newer/cleared question is a silent no-op
    /// rather than answering the wrong one (stale-result protection applies
    /// to the trigger, not just the response). One `CopilotLLM` request:
    /// the question + ≤`config.suggestAnswerMaxRecentTurns` bounded recent
    /// turns + compact state + optional context. A new V2 request of either
    /// kind always cancels whatever V2 request was in flight (plan §7
    /// "Scheduling").
    public func suggestAnswer(questionID: String, contextProvider: (any LiveContextProvider)? = nil) {
        guard state.lastQuestionID == questionID, let question = state.lastQuestion,
              !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let bounds = LiveCopilotPrompts.Bounds(maxRecentTurns: config.suggestAnswerMaxRecentTurns, maxRecentTurnsChars: 4_000)
        let turns = Array(state.recentTurns.suffix(config.suggestAnswerMaxRecentTurns))
        startV2Request(kind: .suggestAnswer, question: question, turns: turns, bounds: bounds, contextProvider: contextProvider)
    }

    /// Triggered by the panel's "Ask Meet Gist" text field (plan §7.2).
    /// Context = turns from the last `config.askWindowMinutes` (char-capped
    /// at `config.askCharCap`) + compact state + optional selected context.
    public func ask(_ question: String, contextProvider: (any LiveContextProvider)? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let windowSeconds = config.askWindowMinutes * 60
        let referenceTime = askTurnHistory.last?.endedAt ?? 0
        let windowed = askTurnHistory.filter { $0.endedAt >= referenceTime - windowSeconds }
        let bounds = LiveCopilotPrompts.Bounds(maxRecentTurns: max(windowed.count, 1), maxRecentTurnsChars: config.askCharCap)
        startV2Request(kind: .ask, question: trimmed, turns: windowed, bounds: bounds, contextProvider: contextProvider)
    }

    private func startV2Request(kind: LiveAssistV2Kind, question: String, turns: [LiveTranscriptTurn],
                                bounds: LiveCopilotPrompts.Bounds, contextProvider: (any LiveContextProvider)?) {
        v2InFlightTask?.cancel()
        v2NextSeq += 1
        let seq = v2NextSeq
        let myGeneration = generation

        guard let llm else {
            v2State.isInFlight = false
            v2State.kind = kind
            v2State.question = question
            v2State.error = "Choose a cloud provider for Live Assist."
            broadcast(currentSnapshot())
            return
        }

        v2State.isInFlight = true
        v2State.kind = kind
        v2State.question = question
        v2State.error = nil
        broadcast(currentSnapshot())

        let compact = state.compactView()
        let evidencePool = (turns.map(\.text) + [compact.topic]
                            + compact.keyPoints.map { $0.text } + compact.decisions
                            + compact.actionItems.map { $0.text }).joined(separator: " ")
        let timeout = llm.providerKind == "codex-cli" ? config.codexAnswerTimeout : config.httpAnswerTimeout
        let purpose: CopilotPurpose = kind == .suggestAnswer ? .suggestAnswer : .ask
        let language = config.language
        let maxOutputTokens = config.answerMaxOutputTokens

        v2InFlightTask = Task { [weak self] in
            var snippets: [ContextSnippet] = []
            if let contextProvider {
                snippets = (try? await contextProvider.snippets(forQuestion: question)) ?? []
            }
            guard !Task.isCancelled else { return }
            let request = CopilotLLMRequest(
                system: LiveCopilotPrompts.answerSystemPrompt(language: language),
                user: LiveCopilotPrompts.answerUserContent(language: language, question: question, state: compact,
                                                           turns: turns, context: snippets, bounds: bounds),
                jsonSchema: LiveCopilotPrompts.answerJSONSchema, maxOutputTokens: maxOutputTokens,
                timeout: timeout, purpose: purpose)
            await self?.runV2Request(request, kind: kind, question: question, seq: seq, generation: myGeneration,
                                     llm: llm, evidencePool: evidencePool, contextFileName: snippets.first?.source)
        }
    }

    private func runV2Request(_ request: CopilotLLMRequest, kind: LiveAssistV2Kind, question: String, seq: Int,
                              generation: Int, llm: any CopilotLLM, evidencePool: String, contextFileName: String?) async {
        do {
            let response = try await Self.withTimeout(request.timeout) { try await llm.complete(request) }
            applyV2Response(response, kind: kind, question: question, seq: seq, generation: generation,
                            providerLabel: llm.label, evidencePool: evidencePool, contextFileName: contextFileName)
        } catch {
            handleV2Failure(error, kind: kind, seq: seq, generation: generation, providerLabel: llm.label)
        }
    }

    private func applyV2Response(_ response: CopilotLLMResponse, kind: LiveAssistV2Kind, question: String, seq: Int,
                                 generation: Int, providerLabel: String, evidencePool: String, contextFileName: String?) {
        defer { finishV2InFlight(seq: seq) }
        metrics.recordV2Success(kind: kind, providerLabel: providerLabel, inputTokens: response.inputTokens,
                                outputTokens: response.outputTokens, latencySeconds: response.latency)
        persistence?.appendMetrics(metrics)
        guard generation == self.generation else { return }   // stopped/disabled/provider changed meanwhile
        guard seq > v2LastAppliedSeq else { return }            // superseded by a newer already-applied response

        do {
            let parsed = try LiveAssistAnswerParser.parse(response.text, providerLabel: providerLabel)
            let checked = LiveAssistAnswerPostCheck.apply(parsed, evidencePool: evidencePool)
            v2LastAppliedSeq = seq
            v2State.answer = checked
            v2State.kind = kind
            v2State.question = question
            v2State.error = nil
            if kind == .ask {
                v2State.askHistory.append(LiveAssistQAEntry(kind: kind, question: question, answer: checked))
                if v2State.askHistory.count > 5 { v2State.askHistory.removeFirst(v2State.askHistory.count - 5) }
            }
            persistence?.appendAssist(LiveAssistAssistLogEntry(
                kind: kind, question: question, answer: checked.answer, provider: providerLabel,
                latencySeconds: response.latency, contextFileName: contextFileName, confidence: checked.confidence))
        } catch {
            v2State.error = "Couldn't understand the answer — try again."
        }
    }

    private func handleV2Failure(_ error: Error, kind: LiveAssistV2Kind, seq: Int, generation: Int, providerLabel: String) {
        defer { finishV2InFlight(seq: seq) }
        metrics.recordV2Failure(kind: kind, providerLabel: providerLabel)
        persistence?.appendMetrics(metrics)
        guard generation == self.generation else { return }    // cancelled by stop()/setLLM(): never publish
        guard seq > v2LastAppliedSeq else { return }            // a newer request already succeeded — don't clobber it
        if error is CancellationError { return }

        if case PipelineError.unsupported(let message) = error, message.contains("Codex CLI") {
            v2State.error = "Codex CLI unavailable."
        } else {
            v2State.error = "Couldn't get an answer — try again."
        }
    }

    /// `seq == v2NextSeq` means this is still the most recently *started*
    /// V2 request — a superseded (cancelled) request's own completion must
    /// not clear `isInFlight`/`v2InFlightTask` out from under whatever
    /// request replaced it (which may already be in flight or already done).
    private func finishV2InFlight(seq: Int) {
        guard seq == v2NextSeq else { return }
        v2State.isInFlight = false
        v2InFlightTask = nil
        broadcast(currentSnapshot())
    }

    private func updateStatus(_ newStatus: LiveAssistSnapshot.Status) {
        status = newStatus
        broadcast(currentSnapshot())
    }

    private func broadcast(_ snapshot: LiveAssistSnapshot) {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Races `operation` against a timer; on timeout, cancels the whole
    /// group (which propagates Swift Task cancellation into `operation` —
    /// for an HTTP adapter that cancels the underlying `URLSession` call,
    /// for the Codex adapter that kills the subprocess via `ChildProcess`).
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError() }
            return result
        }
    }
}
