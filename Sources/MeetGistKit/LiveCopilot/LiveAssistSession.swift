// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Kit-level orchestrator for one recording's Live Assist path (plan §5.10):
/// wires PCM sources → `LiveAudioFeed` → `SpeechEndpointer` (per track) →
/// `RealtimeTranscriber` → `LiveTranscriptTurn` (with timings) →
/// `LiveCopilotEngine`. Owns start/stop/pause/resume for the whole path.
/// Every dependency (transcriber, LLM-backed engine, audio sources) is
/// injected, so this type is fully unit-testable without real audio, Python,
/// or network — `AppState+LiveAssist.swift` (P3) is the only production
/// caller and keeps AppState itself thin: it only ever calls `start`/`stop`/
/// `pause`/`resume`/`setLLM` and observes `snapshots()`.
///
/// Isolation: nothing here can affect `SessionRecorder`/`Recorder` — this
/// actor only reads PCM handed to it through the `LiveAudioSource` seam and
/// never calls back into recording/transcription/notes code.
///
/// Frame ordering (fixed 2026-09-27, review finding F1): every 30 ms frame
/// used to spawn its own unstructured `Task { await self?.handleFrame(...) }`.
/// Unstructured tasks give no FIFO guarantee for *when they enter the actor*
/// — while one was suspended awaiting ASR (~300 ms), a later frame's task
/// could reach the actor first, corrupting endpointer input order and
/// letting turns get ingested out of speech order. The fix has two ordered,
/// bounded stages instead:
///   1. Per track, `LiveAudioFeed`'s frame callback synchronously
///      `yield`s into that track's own `AsyncStream` (never spawns a Task).
///      Exactly one loop task per track (`runFrameLoop`) consumes it,
///      calling the endpointer synchronously — frames can never be
///      processed out of order because there is only one reader and
///      `AsyncStream` preserves yield order.
///   2. Finalized segments (from either track) are hard-order-preserved into
///      one bounded queue (`pendingSegments`, default cap 4, drop-oldest-mic
///      first — same policy `QwenLiveTranscriber` uses for its own queue,
///      applied here too since the session, not the transcriber, now
///      serializes calls one at a time). Exactly one ASR loop task
///      (`runASRLoop`) drains it and calls `transcribeAndIngest` — ASR
///      latency never blocks frame ingestion (stage 1 keeps running
///      independently) and turn IDs/ingestion happen in strict dequeue
///      order.
/// `stop()` finishes both frame streams and wakes the ASR loop's waiter so
/// both stages exit promptly; it deliberately does *not* await the ASR
/// loop's completion (an in-flight `transcriber.transcribe` call may still
/// be resolving, e.g. mid-timeout) — `transcribeAndIngest`'s own
/// `isRunning` re-check (unchanged) still guarantees a stopped session never
/// publishes a turn afterward.
public actor LiveAssistSession {
    public struct Config: Sendable {
        /// Same clock/anchor as `SessionRecorder.recordingAnchorHostNs` — every
        /// turn's `startedAt`/`endedAt`/`timings` are relative to this.
        public var recordingAnchorHostNs: UInt64
        public var endpointerConfig: LiveEndpointerConfig
        /// Bounded queue of finalized-but-not-yet-transcribed segments
        /// shared by both tracks (plan §5.3's "max 4 pending" policy,
        /// applied at the session level per finding F1 — see type doc).
        public var maxPendingSegments: Int

        public init(recordingAnchorHostNs: UInt64, endpointerConfig: LiveEndpointerConfig = LiveEndpointerConfig(),
                    maxPendingSegments: Int = 4) {
            self.recordingAnchorHostNs = recordingAnchorHostNs
            self.endpointerConfig = endpointerConfig
            self.maxPendingSegments = maxPendingSegments
        }
    }

    private struct FrameEvent: Sendable {
        let samples: [Float]
        let startedAt: Double
    }

    private let engine: LiveCopilotEngine
    private let transcriber: any RealtimeTranscriber
    private let speakerSource: any LiveAudioSource
    private let micSource: (any LiveAudioSource)?
    private let recordingAnchorHostNs: UInt64
    private let maxPendingSegments: Int

    private var speakerFeed: LiveAudioFeed?
    private var micFeed: LiveAudioFeed?
    private var speakerEndpointer: SpeechEndpointer
    private var micEndpointer: SpeechEndpointer
    private var nextTurnID = 0
    private var isRunning = false
    private var isPaused = false
    private var asrFailed = false
    private var asrRestartAttempted = false

    // MARK: - Ordering machinery (see type doc "Frame ordering")
    private var frameContinuations: [LiveTrack: AsyncStream<FrameEvent>.Continuation] = [:]
    private var frameLoopTasks: [Task<Void, Never>] = []
    private var pendingSegments: [SpeechSegment] = []
    private var segmentWaiter: CheckedContinuation<Void, Never>?
    private var asrLoopTask: Task<Void, Never>?

    public init(engine: LiveCopilotEngine, transcriber: any RealtimeTranscriber,
                speakerSource: any LiveAudioSource, micSource: (any LiveAudioSource)?,
                config: Config) {
        self.engine = engine
        self.transcriber = transcriber
        self.speakerSource = speakerSource
        self.micSource = micSource
        self.recordingAnchorHostNs = config.recordingAnchorHostNs
        self.maxPendingSegments = max(1, config.maxPendingSegments)
        self.speakerEndpointer = SpeechEndpointer(track: .speaker, config: config.endpointerConfig)
        self.micEndpointer = SpeechEndpointer(track: .me, config: config.endpointerConfig)
    }

    /// A live stream of snapshots — passthrough to the engine's own stream
    /// (see its doc comment: the current snapshot is yielded immediately).
    public func snapshots() async -> AsyncStream<LiveAssistSnapshot> { await engine.snapshots() }
    public func currentSnapshot() async -> LiveAssistSnapshot { await engine.currentSnapshot() }

    /// Swaps the semantic LLM (e.g. the user changed the Live Assist
    /// provider mid-recording) without restarting audio/ASR.
    public func setLLM(_ llm: (any CopilotLLM)?) async {
        await engine.setLLM(llm)
    }

    public func recordUIUpdate(turnID: Int, atHostNs: UInt64 = DispatchTime.now().uptimeNanoseconds) async {
        await engine.recordUIUpdate(forTurnID: turnID, atHostNs: atHostNs)
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7, pure pass-throughs
    // to the engine (no session-level state — the session's job is audio/ASR
    // orchestration, not V2 request bookkeeping).
    public func suggestAnswer(questionID: String, contextProvider: (any LiveContextProvider)? = nil) async {
        await engine.suggestAnswer(questionID: questionID, contextProvider: contextProvider)
    }

    public func ask(_ question: String, contextProvider: (any LiveContextProvider)? = nil) async {
        await engine.ask(question, contextProvider: contextProvider)
    }

    /// Loads the transcriber, then starts both audio sources. A transcriber
    /// that fails to load surfaces `.liveASRNotInstalled`/failure through the
    /// engine's status and leaves the session running with no ASR (turns
    /// simply never arrive) — this must never throw out to the caller (plan
    /// §5.14: "Anything throws in live code" is caught at the AppState
    /// boundary, but this actor already contains every failure mode itself).
    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        do {
            try await transcriber.prepare()
        } catch {
            asrFailed = true
            await engine.setTranscriptionStatus(.liveTranscriptionUnavailable)
        }

        // Single ASR consumer loop (stage 2) — started once, before any
        // segments can possibly exist, so `enqueueSegment` always has a
        // reader (or a soon-to-be waiter) to wake.
        asrLoopTask = Task { [weak self] in await self?.runASRLoop() }

        // The closures passed to `LiveAudioFeed` run off any thread the
        // source's own callback uses (not this actor). They must not touch
        // actor-isolated state directly — `continuation.yield` is safe to
        // call from any thread/queue and preserves the caller's call order,
        // which is exactly the ordering guarantee stage 1 depends on: the
        // per-track `LiveAudioFeed` always calls its own `onFrame` from a
        // single serial queue, so these yields arrive at the stream in the
        // same order the feed produced the frames.
        let (speakerStream, speakerContinuation) = AsyncStream<FrameEvent>.makeStream(bufferingPolicy: .unbounded)
        frameContinuations[.speaker] = speakerContinuation
        let newSpeakerFeed = LiveAudioFeed(track: .speaker, recordingAnchorHostNs: recordingAnchorHostNs) { samples, startedAt in
            speakerContinuation.yield(FrameEvent(samples: samples, startedAt: startedAt))
        }
        do {
            try await speakerSource.start { chunk in
                newSpeakerFeed.ingest(samples: chunk.samples, sampleRate: chunk.sampleRate,
                                      channels: chunk.channels, hostTimeNs: chunk.hostTimeNs)
            }
            speakerFeed = newSpeakerFeed
            frameLoopTasks.append(Task { [weak self] in await self?.runFrameLoop(track: .speaker, stream: speakerStream) })
        } catch {
            // No speaker track is a bigger loss than no mic track, but must
            // still never affect recording — just no Speaker-side turns.
            speakerFeed = nil
            speakerContinuation.finish()
            frameContinuations[.speaker] = nil
        }

        guard let micSource else { return }
        let (micStream, micContinuation) = AsyncStream<FrameEvent>.makeStream(bufferingPolicy: .unbounded)
        frameContinuations[.me] = micContinuation
        let newMicFeed = LiveAudioFeed(track: .me, recordingAnchorHostNs: recordingAnchorHostNs) { samples, startedAt in
            micContinuation.yield(FrameEvent(samples: samples, startedAt: startedAt))
        }
        do {
            try await micSource.start { chunk in
                newMicFeed.ingest(samples: chunk.samples, sampleRate: chunk.sampleRate,
                                  channels: chunk.channels, hostTimeNs: chunk.hostTimeNs)
            }
            micFeed = newMicFeed
            frameLoopTasks.append(Task { [weak self] in await self?.runFrameLoop(track: .me, stream: micStream) })
        } catch {
            // Plan §5.14: mic tap failure → Speaker-only live mode.
            micFeed = nil
            micContinuation.finish()
            frameContinuations[.me] = nil
        }
    }

    /// Ends this session: stops both audio sources, finishes both frame
    /// loops (stage 1), wakes/lets the ASR loop (stage 2) exit, finalizes
    /// engine state, and shuts down the transcriber's subprocess. Safe to
    /// call more than once.
    ///
    /// Deliberately does not await `asrLoopTask`: if a `transcribe` call is
    /// genuinely hung (or, in tests, intentionally released later by the
    /// caller), stop() must still return promptly — `isRunning` being false
    /// already guarantees nothing more gets published once that call
    /// eventually resolves.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        await speakerSource.stop()
        if let micSource { await micSource.stop() }

        for (_, continuation) in frameContinuations { continuation.finish() }
        frameContinuations.removeAll()
        speakerFeed = nil
        micFeed = nil

        if let waiter = segmentWaiter {
            segmentWaiter = nil
            waiter.resume()
        }

        for task in frameLoopTasks { await task.value }
        frameLoopTasks.removeAll()
        asrLoopTask = nil

        await engine.stop()
        await transcriber.shutdown()
    }

    /// While paused, incoming audio is dropped and any open segment is
    /// finalized/discarded (plan §5.1) rather than spanning the pause gap.
    public func pause() async {
        isPaused = true
        _ = speakerEndpointer.flush()
        _ = micEndpointer.flush()
        speakerFeed?.reset()
        micFeed?.reset()
    }

    public func resume() async {
        isPaused = false
    }

    // MARK: - Stage 1: ordered per-track frame consumption

    /// The only reader of `stream` — processes every event strictly in
    /// yield order, one at a time. `SpeechEndpointer.process` is pure and
    /// synchronous, so this loop never suspends except at `for await`
    /// itself, meaning it can never be reentered mid-frame.
    private func runFrameLoop(track: LiveTrack, stream: AsyncStream<FrameEvent>) async {
        for await event in stream {
            guard isRunning, !isPaused else { continue }
            let segment: SpeechSegment?
            switch track {
            case .speaker: segment = speakerEndpointer.process(frame: event.samples, atSeconds: event.startedAt)
            case .me: segment = micEndpointer.process(frame: event.samples, atSeconds: event.startedAt)
            }
            if let segment { enqueueSegment(segment) }
        }
    }

    /// Bounded, ordered hand-off from stage 1 to stage 2 (plan §5.3's
    /// drop policy, applied here since the session — not the transcriber —
    /// now serializes ASR calls one at a time): once at capacity, drop the
    /// oldest still-queued **mic** segment first (never one already
    /// dispatched), else the oldest queued segment overall.
    private func enqueueSegment(_ segment: SpeechSegment) {
        if pendingSegments.count >= maxPendingSegments {
            if let dropIndex = pendingSegments.firstIndex(where: { $0.track == .me }) {
                pendingSegments.remove(at: dropIndex)
            } else {
                pendingSegments.removeFirst()
            }
        }
        pendingSegments.append(segment)
        if let waiter = segmentWaiter {
            segmentWaiter = nil
            waiter.resume()
        }
    }

    // MARK: - Stage 2: single ordered ASR consumer

    /// The only caller of `transcriber.transcribe` — segments are drained
    /// and transcribed strictly one at a time, in the order they were
    /// finalized, so turn IDs and engine ingestion order always match
    /// speech order. ASR latency here never blocks stage 1: frames keep
    /// arriving and being endpointed on their own loops while this awaits.
    private func runASRLoop() async {
        while true {
            if !isRunning { return }
            if pendingSegments.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    segmentWaiter = continuation
                }
                continue
            }
            let segment = pendingSegments.removeFirst()
            await transcribeAndIngest(segment)
        }
    }

    private func transcribeAndIngest(_ segment: SpeechSegment) async {
        let turnID = nextTurnID
        nextTurnID += 1
        let speechEndHostNs = recordingAnchorHostNs &+ UInt64(max(0, segment.endedAt) * 1_000_000_000)
        var timings = LiveTurnTimings(speechEndHostNs: speechEndHostNs)
        timings.asrStartHostNs = DispatchTime.now().uptimeNanoseconds
        do {
            let text = try await transcriber.transcribe(segment)
            // `stop()` may have run while this transcription was in flight —
            // an actor call resumes seeing every mutation made meanwhile, so
            // this re-check is enough to guarantee a stopped session never
            // publishes a turn afterward (plan §5.14/§8).
            guard isRunning else { return }
            timings.asrEndHostNs = DispatchTime.now().uptimeNanoseconds
            if asrFailed {
                asrFailed = false
                await engine.setTranscriptionStatus(.listening)
            }
            let turn = LiveTranscriptTurn(id: turnID, track: segment.track, startedAt: segment.startedAt,
                                         endedAt: segment.endedAt, text: text, timings: timings)
            await engine.ingest(turn)
        } catch {
            guard isRunning else { return }
            await handleTranscriptionFailure(error)
        }
    }

    /// Plan §5.3/§5.14: worker crash → status "Live transcription
    /// unavailable"; at most one automatic restart per recording.
    private func handleTranscriptionFailure(_ error: Error) async {
        asrFailed = true
        await engine.setTranscriptionStatus(.liveTranscriptionUnavailable)
        guard !asrRestartAttempted else { return }
        asrRestartAttempted = true
        await transcriber.shutdown()
        do {
            try await transcriber.prepare()
            asrFailed = false
            await engine.setTranscriptionStatus(.listening)
        } catch {
            // Stays failed for the rest of this recording — no further retries.
        }
    }
}
