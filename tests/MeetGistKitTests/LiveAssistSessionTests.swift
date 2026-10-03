// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

/// A fake `LiveAudioSource` that hands the test its `onChunk` callback so it
/// can drive synthetic PCM directly — no real audio, no `AVAudioEngine`.
private final class FakeAudioSource: LiveAudioSource, @unchecked Sendable {
    private(set) var started = false
    private(set) var stopped = false
    var onChunkCallback: (@Sendable (LivePCMChunk) -> Void)?
    var startError: Error?

    func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws {
        if let startError { throw startError }
        onChunkCallback = onChunk
        started = true
    }

    func stop() async { stopped = true }

    /// Feeds `seconds` of a loud (voiced) or silent tone at 16 kHz mono —
    /// matches `LiveEndpointerConfig`'s default sample rate exactly, so
    /// `LiveAudioFeed` never needs to resample.
    func feed(seconds: Double, loud: Bool, startHostNs: UInt64) {
        guard let onChunkCallback else { return }
        let sampleRate = 16_000.0
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        if loud {
            for i in 0..<count { samples[i] = Float(sin(Double(i) * 0.6)) * 0.9 }
        }
        onChunkCallback(LivePCMChunk(samples: samples, sampleRate: sampleRate, channels: 1, hostTimeNs: startHostNs))
    }
}

private enum FakeTranscriberError: Error { case boom, prepareFailed }

/// A scriptable fake `RealtimeTranscriber`. `behaviors` are consumed in
/// order (one per `transcribe` call); once exhausted the last one repeats.
private actor FakeTranscriber: RealtimeTranscriber {
    enum Behavior { case respond(String); case respondSlow(String, TimeInterval); case fail(Error); case hang }

    nonisolated let label = "Fake Live ASR"
    private var behaviors: [Behavior]
    private var prepareShouldFail: Bool
    private(set) var prepareCount = 0
    private(set) var shutdownCount = 0
    private(set) var transcribedSegments: [SpeechSegment] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(behaviors: [Behavior] = [.respond("hello")], prepareShouldFail: Bool = false) {
        self.behaviors = behaviors
        self.prepareShouldFail = prepareShouldFail
    }

    func prepare() async throws {
        prepareCount += 1
        if prepareShouldFail { throw FakeTranscriberError.prepareFailed }
    }

    /// Test control: makes every subsequent `prepare()` call fail, e.g. to
    /// simulate the one automatic restart attempt itself failing.
    func failPrepareFromNowOn() { prepareShouldFail = true }

    func transcribe(_ segment: SpeechSegment) async throws -> String {
        transcribedSegments.append(segment)
        let behavior = behaviors.isEmpty ? .respond("hello") : behaviors.removeFirst()
        switch behavior {
        case .respond(let text): return text
        case .respondSlow(let text, let delaySeconds):
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            return text
        case .fail(let error): throw error
        case .hang:
            if released { return "late" }
            await withCheckedContinuation { releaseContinuations.append($0) }
            return "late"
        }
    }

    func shutdown() async { shutdownCount += 1 }

    func release() {
        released = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }
}

private func waitUntil(timeoutSeconds: Double = 2, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Minimal `CopilotLLM` fake — Live Assist Session tests care about the
/// ASR/turn/engine wiring, not semantic parsing (already covered by
/// `LiveCopilotEngineTests`), so this always returns a fixed, valid result.
private struct AlwaysRespondLLM: CopilotLLM {
    let label = "fake"
    let providerKind = "chat"
    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        let json = """
        {"meaning": "test meaning", "speech_act": "statement", "is_question": false,
         "question": "", "topic": "", "key_points": [], "decisions": [], "action_items": [],
         "open_questions": [], "resolved_open_question_ids": []}
        """
        return CopilotLLMResponse(text: json, inputTokens: 1, outputTokens: 1, latency: 0.001, providerLabel: label)
    }
}

@Suite struct LiveAssistSessionTests {
    private func makeSession(transcriber: FakeTranscriber, llm: (any CopilotLLM)? = AlwaysRespondLLM(),
                             mic: FakeAudioSource? = nil, maxPendingSegments: Int = 4) -> (session: LiveAssistSession, speaker: FakeAudioSource) {
        let engine = LiveCopilotEngine(config: LiveCopilotEngine.Config(), llm: llm)
        let speaker = FakeAudioSource()
        let config = LiveAssistSession.Config(recordingAnchorHostNs: 1_000_000_000, maxPendingSegments: maxPendingSegments)
        let session = LiveAssistSession(engine: engine, transcriber: transcriber, speakerSource: speaker,
                                        micSource: mic, config: config)
        return (session, speaker)
    }

    @Test func turnFlowsFromAudioThroughToASnapshot() async throws {
        let transcriber = FakeTranscriber(behaviors: [.respond("what is the deadline")])
        let (session, speaker) = makeSession(transcriber: transcriber)
        await session.start()
        #expect(speaker.started)

        // ~1s of voiced audio, then >600ms silence to close the segment via hangover.
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 2_000_000_000)

        await waitUntil { await session.currentSnapshot().latestTranscriptTurn != nil }
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.latestTranscriptTurn?.text == "what is the deadline")
        #expect(snapshot.latestTranscriptTurn?.timings.speechEndHostNs != nil)
        #expect(snapshot.latestTranscriptTurn?.timings.asrStartHostNs != nil)
        #expect(snapshot.latestTranscriptTurn?.timings.asrEndHostNs != nil)

        await waitUntil { await session.currentSnapshot().lastMeaning == "test meaning" }
        #expect(await session.currentSnapshot().lastMeaning == "test meaning")

        await session.stop()
        #expect(await transcriber.shutdownCount == 1)
    }

    @Test func pauseFinalizesAndDiscardsAnIncompleteSegmentAndResumeStillWorks() async throws {
        let transcriber = FakeTranscriber(behaviors: [.respond("after resume")])
        let (session, speaker) = makeSession(transcriber: transcriber)
        await session.start()

        // Only 300ms voiced — below `minVoicedSeconds` (500ms default), so
        // `pause()`'s flush must discard it silently (no transcribe call).
        speaker.feed(seconds: 0.3, loud: true, startHostNs: 1_000_000_000)
        await session.pause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transcriber.transcribedSegments.isEmpty)

        await session.resume()
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 5_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 6_000_000_000)
        await waitUntil { await !transcriber.transcribedSegments.isEmpty }
        #expect(await transcriber.transcribedSegments.count == 1)
        await waitUntil { await session.currentSnapshot().latestTranscriptTurn?.text == "after resume" }
    }

    @Test func asrFailureDegradesStatusAndOneRestartIsAttempted() async throws {
        // prepare() succeeds at start(), but every transcribe() throws, and
        // the one automatic restart's prepare() also fails — status must
        // stay "unavailable" for the rest of the recording, with no more
        // than one restart attempted no matter how many turns keep failing.
        let transcriber = FakeTranscriber(behaviors: [.fail(FakeTranscriberError.boom)], prepareShouldFail: false)
        let (session, speaker) = makeSession(transcriber: transcriber)
        await session.start()
        await transcriber.failPrepareFromNowOn()

        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 2_000_000_000)

        // First failure triggers the one allowed restart attempt, which
        // itself fails (prepare() now always throws) — status stays
        // unavailable.
        await waitUntil { await transcriber.prepareCount >= 2 }
        #expect(await transcriber.prepareCount == 2)
        await waitUntil { await session.currentSnapshot().status == .liveTranscriptionUnavailable }
        #expect(await session.currentSnapshot().status == .liveTranscriptionUnavailable)

        // A second failing turn must not attempt a second restart.
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 5_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 6_000_000_000)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await transcriber.prepareCount == 2)
    }

    @Test func stopWhileTranscriptionInFlightNeverPublishes() async throws {
        let transcriber = FakeTranscriber(behaviors: [.hang])
        let (session, speaker) = makeSession(transcriber: transcriber)
        await session.start()

        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 2_000_000_000)
        // Give the endpointer/feed pipeline time to finalize the segment and
        // reach the (hanging) transcribe() call.
        await waitUntil { await transcriber.transcribedSegments.count == 1 }

        await session.stop()
        await transcriber.release()
        try await Task.sleep(for: .milliseconds(150))
        // The late "hello"/"late" result must never have reached the engine.
        #expect(await session.currentSnapshot().latestTranscriptTurn == nil)
    }

    @Test func micTapFailureFallsBackToSpeakerOnlyLiveMode() async throws {
        let transcriber = FakeTranscriber()
        let mic = FakeAudioSource()
        mic.startError = FakeTranscriberError.boom
        let (session, speaker) = makeSession(transcriber: transcriber, mic: mic)
        await session.start()
        #expect(speaker.started)
        #expect(!mic.started)
        // Speaker-only mode must still work end to end.
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 2_000_000_000)
        await waitUntil { await session.currentSnapshot().latestTranscriptTurn != nil }
        #expect(await session.currentSnapshot().latestTranscriptTurn != nil)
    }

    /// Regression test for review finding F1 (frame ordering / actor
    /// reentrancy): the old design spawned an unstructured
    /// `Task { await self?.handleFrame(...) }` per 30 ms frame, with no FIFO
    /// guarantee for when each task actually reached the actor — while one
    /// was suspended awaiting a slow ASR call, later frames could reach the
    /// endpointer out of order. Each `speaker.feed(...)` call below produces
    /// dozens of 30 ms frames in one synchronous burst (exactly the pattern
    /// that used to race), and the transcriber deliberately takes longer
    /// than the gap between segments so ASR is still "busy" when later
    /// frames/segments are produced.
    @Test func framesAndSegmentsStayOrderedAndUnlostWhileASRIsBusy() async throws {
        let transcriber = FakeTranscriber(behaviors: [
            .respondSlow("turn-0", 0.05), .respondSlow("turn-1", 0.05), .respondSlow("turn-2", 0.05),
        ])
        let (session, speaker) = makeSession(transcriber: transcriber)
        await session.start()

        for i in 0..<3 {
            let base = UInt64(i) * 3_000_000_000 + 1_000_000_000
            speaker.feed(seconds: 1.0, loud: true, startHostNs: base)
            speaker.feed(seconds: 0.7, loud: false, startHostNs: base + 1_000_000_000)
        }

        await waitUntil(timeoutSeconds: 5) { await transcriber.transcribedSegments.count == 3 }
        let segments = await transcriber.transcribedSegments
        #expect(segments.count == 3)
        // No frames/segments lost: exactly the 3 finalized speaker segments
        // were dispatched, none dropped (well under the default capacity).
        #expect(segments.allSatisfy { $0.track == .speaker })
        // Contiguous/ordered: each segment's start time strictly follows the
        // previous one — the old design could interleave/reorder these.
        let starts = segments.map { $0.startedAt }
        #expect(starts == starts.sorted())
        #expect(Set(starts).count == starts.count)

        await waitUntil(timeoutSeconds: 5) { await session.currentSnapshot().latestTranscriptTurn?.text == "turn-2" }
        // Turn IDs assigned/ingested strictly in speech order, never out of
        // order despite the slow, overlapping-with-arrival ASR responses.
        #expect(await session.currentSnapshot().latestTranscriptTurn?.id == 2)
        #expect(await session.currentSnapshot().latestTranscriptTurn?.text == "turn-2")

        await session.stop()
    }

    /// Regression test for F1's bounded-queue policy, now enforced at the
    /// session level (plan §5.3: max pending, drop oldest **mic** first)
    /// since the session — not the transcriber — serializes ASR calls one
    /// at a time. Backs up 3 more segments behind one hanging ASR call with
    /// a capacity of 2, then verifies the eventually-transcribed set always
    /// keeps a queued speaker segment over a queued mic segment.
    @Test func pendingSegmentQueueDropsOldestMicSegmentFirstWhenBackloggedByASR() async throws {
        let transcriber = FakeTranscriber(behaviors: [.hang, .respond("second"), .respond("third")])
        let mic = FakeAudioSource()
        let (session, speaker) = makeSession(transcriber: transcriber, mic: mic, maxPendingSegments: 2)
        await session.start()

        // Segment 1 (speaker) starts the hanging in-flight transcribe() call.
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 2_000_000_000)
        await waitUntil { await transcriber.transcribedSegments.count == 1 }

        // 2 more mic segments + 1 more speaker segment finalize while ASR is
        // still stuck on segment 1 — capacity 2 means at least one queued
        // segment must be dropped; it must always be a mic one.
        mic.feed(seconds: 1.0, loud: true, startHostNs: 3_000_000_000)
        mic.feed(seconds: 0.7, loud: false, startHostNs: 4_000_000_000)
        speaker.feed(seconds: 1.0, loud: true, startHostNs: 5_000_000_000)
        speaker.feed(seconds: 0.7, loud: false, startHostNs: 6_000_000_000)
        mic.feed(seconds: 1.0, loud: true, startHostNs: 7_000_000_000)
        mic.feed(seconds: 0.7, loud: false, startHostNs: 8_000_000_000)
        try await Task.sleep(for: .milliseconds(200))

        await transcriber.release()
        await waitUntil(timeoutSeconds: 5) { await transcriber.transcribedSegments.count == 3 }

        let tracks = await transcriber.transcribedSegments.map { $0.track }
        #expect(tracks.count == 3)
        #expect(tracks.first == .speaker) // the original in-flight segment
        #expect(tracks.filter { $0 == .speaker }.count == 2) // both speaker segments survive
        #expect(tracks.filter { $0 == .me }.count == 1) // exactly one of the two mic segments was dropped

        await session.stop()
    }
}
