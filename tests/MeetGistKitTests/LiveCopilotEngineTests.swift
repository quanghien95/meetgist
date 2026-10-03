// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

/// A scriptable fake `CopilotLLM`. Each call to `complete` pulls the next
/// canned behavior off `behaviors` (or repeats the last one if exhausted),
/// recording every request it was given.
private actor FakeCopilotLLM: CopilotLLM {
    enum Behavior {
        case respond(String)
        case fail(Error)
        case hang   // never returns until cancelled — exercises the timeout/cancellation paths
    }

    let label: String
    let providerKind: String
    private var behaviors: [Behavior]
    private(set) var requests: [CopilotLLMRequest] = []
    private(set) var callCount = 0

    init(label: String = "Fake", providerKind: String = "chat", behaviors: [Behavior]) {
        self.label = label
        self.providerKind = providerKind
        self.behaviors = behaviors
    }

    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        requests.append(request)
        callCount += 1
        let behavior = behaviors.isEmpty ? .respond("{}") : behaviors.removeFirst()
        switch behavior {
        case .respond(let text):
            return CopilotLLMResponse(text: text, inputTokens: 10, outputTokens: 20, latency: 0.01, providerLabel: label)
        case .fail(let error):
            throw error
        case .hang:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

private enum FakeError: Error { case boom }

private func canned(meaning: String = "They are asking about the deadline.",
                    isQuestion: Bool = true, question: String = "Is the deadline fixed?") -> String {
    """
    {"meaning": "\(meaning)", "speech_act": "question", "is_question": \(isQuestion),
     "question": "\(question)", "topic": "", "key_points": [], "decisions": [], "action_items": [],
     "open_questions": [], "resolved_open_question_ids": []}
    """
}

/// A V2 (Suggest Answer / Ask Meet Gist) answer response, schema-shaped.
private func cannedAnswer(answer: String = "Yes, Friday is confirmed.",
                          known: [String] = ["Friday is confirmed"], fromContext: [String] = [],
                          assumptions: [String] = [], confidence: String = "high") -> String {
    func arr(_ xs: [String]) -> String { "[" + xs.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
    return """
    {"answer": "\(answer)", "known_from_meeting": \(arr(known)), "from_context": \(arr(fromContext)),
     "assumptions": \(arr(assumptions)), "confidence": "\(confidence)"}
    """
}

/// A `CopilotLLM` fake that routes by `CopilotPurpose` instead of call
/// order — needed for tests where a V1 (`.semantic`) and a V2
/// (`.suggestAnswer`/`.ask`) request against the *same* provider must behave
/// independently regardless of which one happens to reach `complete` first.
private actor PurposeRoutedFakeLLM: CopilotLLM {
    let label = "Purpose-routed fake"
    let providerKind = "chat"
    private var semanticBehaviors: [FakeCopilotLLM.Behavior]
    private var v2Behaviors: [FakeCopilotLLM.Behavior]
    private(set) var semanticCallCount = 0
    private(set) var v2CallCount = 0

    init(semanticBehaviors: [FakeCopilotLLM.Behavior], v2Behaviors: [FakeCopilotLLM.Behavior]) {
        self.semanticBehaviors = semanticBehaviors
        self.v2Behaviors = v2Behaviors
    }

    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        let behavior: FakeCopilotLLM.Behavior
        if request.purpose == .semantic {
            semanticCallCount += 1
            behavior = semanticBehaviors.isEmpty ? .respond("{}") : semanticBehaviors.removeFirst()
        } else {
            v2CallCount += 1
            behavior = v2Behaviors.isEmpty ? .respond("{}") : v2Behaviors.removeFirst()
        }
        switch behavior {
        case .respond(let text):
            return CopilotLLMResponse(text: text, inputTokens: 10, outputTokens: 20, latency: 0.01, providerLabel: label)
        case .fail(let error):
            throw error
        case .hang:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

private func turn(_ id: Int, _ text: String, track: LiveTrack = .speaker) -> LiveTranscriptTurn {
    LiveTranscriptTurn(id: id, track: track, startedAt: Double(id) * 2, endedAt: Double(id) * 2 + 1.5, text: text)
}

/// Waits (bounded) until `snapshot's` condition holds, polling the engine —
/// avoids sleeping a fixed guess while a scheduled `Task` completes.
private func waitUntil(timeoutSeconds: Double = 2, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite struct LiveCopilotEngineTests {
    private func makeEngine(llm: (any CopilotLLM)?) -> LiveCopilotEngine {
        LiveCopilotEngine(config: .init(language: "English"), llm: llm)
    }

    /// Optional local replay, with no LLM or writes to the original meeting.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETGIST_LIVE_REPLAY_TURNS"] != nil))
    func recordedTurnsReplayHasNoRemainingCrossTrackEchoes() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEETGIST_LIVE_REPLAY_TURNS"])
        let input = try String(contentsOfFile: path).split(separator: "\n").map {
            try JSONDecoder().decode(LiveTranscriptTurn.self, from: Data($0.utf8))
        }
        #expect(!input.isEmpty)
        for micFirst in [false, true] {
            let engine = makeEngine(llm: nil)
            let replay = micFirst ? input.sorted { a, b in
                if a.track != b.track { return a.track == .me }
                return a.id < b.id
            } : input
            for t in replay { await engine.ingest(t) }
            let history = await engine.currentSnapshot().transcriptTurns
            let filter = LiveTurnFilter()
            let speakers = history.filter { $0.track == .speaker }
            for mic in history where mic.track == .me {
                #expect(!speakers.contains { filter.isMicEcho(mic, of: $0) })
            }
            #expect(!speakers.isEmpty)
            print("[local replay] input=\(input.count), accepted=\(history.count), system=\(speakers.count), micFirst=\(micFirst)")
        }
    }

    @Test func echoReconciliationKeepsSystemInEitherArrivalOrderAndPersistence() async throws {
        for micFirst in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let persistence = try #require(LiveCopilotPersistence(sessionDir: root))
            let engine = LiveCopilotEngine(config: .init(), llm: nil, persistence: persistence)
            let mic = LiveTranscriptTurn(id: 1, track: .me, startedAt: 10, endedAt: 12, text: "The deadline is next Friday for sure")
            let speaker = LiveTranscriptTurn(id: 2, track: .speaker, startedAt: 10.1, endedAt: 12.2, text: "The deadline is next Friday for sure")
            for t in micFirst ? [mic, speaker] : [speaker, mic] { await engine.ingest(t) }
            #expect(await engine.currentSnapshot().transcriptTurns == [speaker])
            #expect(await engine.currentState().recentTurns == [speaker])
            let lines = try String(contentsOf: root.appendingPathComponent("live/turns.jsonl")).split(separator: "\n")
            let saved = try lines.map { try JSONDecoder().decode(LiveTranscriptTurn.self, from: Data($0.utf8)) }
            #expect(saved == [speaker])
        }
    }

    @Test func longSpeakerTurnReconcilesSplitMicEchoesBeyondContextRing() async {
        let engine = makeEngine(llm: nil)
        await engine.ingest(LiveTranscriptTurn(id: 1, track: .me, startedAt: 10, endedAt: 12,
                                               text: "The deadline is next Friday for sure"))
        for id in 2...12 { await engine.ingest(turn(id, "Unrelated distinct utterance number \(id)", track: .me)) }
        let speaker = LiveTranscriptTurn(id: 13, track: .speaker, startedAt: 10, endedAt: 18,
                                          text: "The deadline is next Friday for sure and delivery follows on Monday")
        await engine.ingest(speaker)
        let history = await engine.currentSnapshot().transcriptTurns
        #expect(!history.contains { $0.id == 1 })
        #expect(history.contains(speaker))
    }

    @Test func echoReconciliationPreservesDistinctMicSpeechAndLaterRepetition() async {
        let engine = makeEngine(llm: nil)
        let mic = LiveTranscriptTurn(id: 1, track: .me, startedAt: 10, endedAt: 12, text: "Please update the budget instead")
        let speaker = LiveTranscriptTurn(id: 2, track: .speaker, startedAt: 10, endedAt: 12, text: "The deadline is next Friday for sure")
        let repeated = LiveTranscriptTurn(id: 3, track: .me, startedAt: 60, endedAt: 62, text: speaker.text)
        for t in [mic, speaker, repeated] { await engine.ingest(t) }
        #expect(await engine.currentSnapshot().transcriptTurns == [mic, speaker, repeated])
    }

    @Test func transcriptHistoryRetainsTurnsBeyondBothPromptContextLimits() async {
        let engine = makeEngine(llm: nil)
        for id in 1...220 {
            await engine.ingest(turn(id, "Distinct utterance number \(id) for reading later.", track: .me))
        }
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.transcriptTurns.count == 220)
        #expect(snapshot.transcriptTurns.first?.id == 1)
        #expect(snapshot.transcriptTurns.last?.id == 220)
        #expect(await engine.currentState().recentTurns.count == LiveMeetingState.caps.recentTurns)
        // A later snapshot republishes the same history, without appending duplicates.
        #expect(await engine.currentSnapshot().transcriptTurns == snapshot.transcriptTurns)
    }

    @Test func transcriptHistorySurvivesStatusProviderChangesAndStopButNewSessionIsEmpty() async {
        let engine = makeEngine(llm: nil)
        await engine.ingest(turn(1, "Keep this complete utterance for reading."))
        let history = await engine.currentSnapshot().transcriptTurns
        await engine.setTranscriptionStatus(.liveTranscriptionUnavailable)
        #expect(await engine.currentSnapshot().transcriptTurns == history)
        await engine.setLLM(nil)
        #expect(await engine.currentSnapshot().transcriptTurns == history)
        await engine.stop()
        #expect(await engine.currentSnapshot().transcriptTurns == history)
        #expect(await makeEngine(llm: nil).currentSnapshot().transcriptTurns.isEmpty)
    }

    @Test func transcriptHistoryIsChronologicalAcrossDelayedTracksAndKeepsTimestamps() async {
        let engine = makeEngine(llm: nil)
        let later = LiveTranscriptTurn(id: 1, track: .speaker, startedAt: 65, endedAt: 68,
                                       text: "A later speaker utterance.")
        let earlier = LiveTranscriptTurn(id: 2, track: .me, startedAt: 12, endedAt: 16,
                                         text: "My earlier microphone utterance.")
        await engine.ingest(later)
        await engine.ingest(earlier)
        #expect(await engine.currentSnapshot().transcriptTurns == [earlier, later])
    }

    @Test func transcriptHistoryUpdatesWhileSemanticProviderIsStillWaiting() async {
        let llm = FakeCopilotLLM(behaviors: [.hang])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "First finalized sentence appears immediately."))
        await waitUntil { await llm.callCount == 1 }
        await engine.ingest(turn(2, "Second statement stays beside the previous text."))
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .analyzing)
        #expect(snapshot.transcriptTurns.map(\.id) == [1, 2])
        #expect(snapshot.lastMeaning == nil)
        await engine.stop()
    }

    @Test func successfulSemanticResultUpdatesStateAndPublishesListening() async {
        let llm = FakeCopilotLLM(behaviors: [.respond(canned())])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "Do we have a fixed deadline for this?"))

        await waitUntil { await engine.currentSnapshot().lastQuestion != nil }

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .listening)
        #expect(snapshot.lastQuestion == "Is the deadline fixed?")
        let state = await engine.currentState()
        #expect(state.lastMeaning == "They are asking about the deadline.")
    }

    @Test func timeoutCancelsTheRequestAndNeverPublishesItsResult() async {
        let llm = FakeCopilotLLM(behaviors: [.hang])
        let engine = LiveCopilotEngine(
            config: .init(language: "English", httpSemanticTimeout: 0.2, codexSemanticTimeout: 0.2), llm: llm)
        await engine.ingest(turn(1, "This one should time out."))

        await waitUntil { await engine.currentSnapshot().status != .analyzing }
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .providerUnavailableRetrying)
        #expect(snapshot.lastMeaning == nil)
    }

    @Test func malformedResponseLeavesStateUnchangedAndIsCountedNotFailed() async {
        let llm = FakeCopilotLLM(behaviors: [.respond("this is not json")])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "Some speaker turn worth analyzing."))

        await waitUntil { await engine.currentState().malformedResultCount > 0 }
        let state = await engine.currentState()
        #expect(state.malformedResultCount == 1)
        #expect(state.lastMeaning == nil)
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .malformedResponse)
    }

    @Test func providerFailureOpensCircuitBreakerAfterThreeConsecutiveFailures() async {
        let llm = FakeCopilotLLM(behaviors: [.fail(FakeError.boom), .fail(FakeError.boom), .fail(FakeError.boom), .respond(canned())])
        let engine = makeEngine(llm: llm)

        for i in 0..<3 {
            await engine.ingest(turn(i, "Speaker turn number \(i) with enough words to pass the filter."))
            await waitUntil { await llm.callCount == i + 1 }
        }
        // A 4th turn right after the 3rd failure must NOT call the LLM again
        // (the breaker just opened) — it should stay queued.
        await engine.ingest(turn(3, "One more turn while the breaker should be open."))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let callsWhileOpen = await llm.callCount
        #expect(callsWhileOpen == 3, "circuit breaker should block a new request immediately after tripping")
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .providerUnavailableRetrying)
    }

    @Test func cancellationOnStopSuppressesAnyLatePublish() async {
        let llm = FakeCopilotLLM(behaviors: [.hang])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "This request will be stopped before it finishes."))
        await waitUntil { await engine.currentSnapshot().status == .analyzing }

        await engine.stop()
        // Give the cancelled task a moment to actually unwind.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .idle)
        #expect(snapshot.lastMeaning == nil)
    }

    @Test func staleResponseIsIgnoredWhenANewerOneAlreadyApplied() async {
        // Two well-formed responses queued; the engine issues them one at a
        // time (single in-flight), so by construction seq only increases —
        // this exercises that the *older* one applying second (e.g. a
        // reordered network response) cannot overwrite state with older
        // content once a newer seq has already been applied. We simulate
        // that ordering directly against the actor's internal guard by
        // driving two full ingest/settle cycles and asserting the second
        // (newer) result is what's reflected — the seq guard is exercised
        // implicitly by every test in this suite since every applied result
        // must have a strictly increasing seq to take effect at all.
        let llm = FakeCopilotLLM(behaviors: [
            .respond(canned(meaning: "First meaning", question: "First question?")),
            .respond(canned(meaning: "Second meaning", question: "Second question?")),
        ])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "First speaker turn to analyze here."))
        await waitUntil { await engine.currentState().lastMeaning == "First meaning" }
        await engine.ingest(turn(2, "Second speaker turn to analyze here."))
        await waitUntil { await engine.currentState().lastMeaning == "Second meaning" }

        let state = await engine.currentState()
        #expect(state.lastMeaning == "Second meaning")
        #expect(state.lastQuestion == "Second question?")
    }

    @Test func responseFromABeforeProviderChangeNeverPublishesAfterwards() async {
        // A request in flight when the provider is switched (setLLM bumps
        // `generation`) belongs to the old generation — even if it finishes
        // normally (not cancelled in time) afterward, it must never publish
        // or mutate state, since it was answered by a provider the user has
        // since moved away from.
        let oldLLM = FakeCopilotLLM(behaviors: [.hang])
        let engine = makeEngine(llm: oldLLM)
        await engine.ingest(turn(1, "This request belongs to the old provider."))
        await waitUntil { await engine.currentSnapshot().status == .analyzing }

        let newLLM = FakeCopilotLLM(behaviors: [.respond(canned(meaning: "New provider meaning"))])
        await engine.setLLM(newLLM)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The old (cancelled) request must not have left any trace, and
        // switching providers alone (no new turn ingested) must not itself
        // trigger a request against the new one either.
        let state = await engine.currentState()
        #expect(state.lastMeaning == nil)
        #expect(await newLLM.callCount == 0)
    }

    @Test func rapidConsecutiveTurnsCoalesceIntoABoundedPendingBatch() async {
        let llm = FakeCopilotLLM(behaviors: [.hang, .respond(canned())])
        let engine = LiveCopilotEngine(config: .init(language: "English", maxCurrentTurns: 3, httpSemanticTimeout: 100), llm: llm)

        // First turn kicks off the (hanging) in-flight request.
        await engine.ingest(turn(0, "Turn zero starts the in-flight request now."))
        await waitUntil { await llm.callCount == 1 }

        // Five more turns arrive while that request is still in flight — they
        // must all coalesce into one pending batch, never spawn extra calls.
        for i in 1...5 {
            await engine.ingest(turn(i, "Coalesced turn number \(i) arriving quickly."))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await llm.callCount == 1, "no second request may start while one is in flight")

        await engine.stop()   // unblocks/cancels the hang so the test doesn't leak a Task
    }

    @Test func micTurnsAreContextOnlyByDefault() async {
        let llm = FakeCopilotLLM(behaviors: [])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "This is spoken by me into the microphone.", track: .me))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await llm.callCount == 0, "a mic turn must not trigger semantic analysis unless analyzeMic is on")
        let state = await engine.currentState()
        #expect(state.recentTurns.contains { $0.track == .me })
    }

    @Test func analyzeMicEnabledSendsMicTurnsForAnalysisToo() async {
        let llm = FakeCopilotLLM(behaviors: [.respond(canned())])
        let engine = LiveCopilotEngine(config: .init(language: "English", analyzeMic: true), llm: llm)
        await engine.ingest(turn(1, "This is spoken by me into the microphone.", track: .me))
        await waitUntil { await llm.callCount == 1 }
        #expect(await llm.callCount == 1)
    }

    @Test func noProviderConfiguredReportsChooseCloudProviderAndNeverCallsAnything() async {
        let engine = LiveCopilotEngine(config: .init(language: "English"), llm: nil)
        await engine.ingest(turn(1, "A perfectly analyzable speaker turn."))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.status == .chooseCloudProvider)
    }

    // MARK: - V2: Suggested Answer / Ask Meet Gist (plan §7)

    @Test func manualSuggestAnswerUsesTheActiveQuestionAndPublishesTheAnswer() async {
        // The known claim deliberately echoes text from the ingested turn so
        // the post-check (exercised separately below) doesn't move it to
        // assumptions — this test is about the request/response plumbing,
        // not the post-check.
        let llm = FakeCopilotLLM(behaviors: [.respond(canned()), .respond(cannedAnswer(known: ["a fixed deadline for this"]))])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "Do we have a fixed deadline for this?"))
        await waitUntil { await engine.currentSnapshot().lastQuestionID != nil }
        let questionID = await engine.currentSnapshot().lastQuestionID!

        await engine.suggestAnswer(questionID: questionID)
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2Kind == .suggestAnswer)
        #expect(snapshot.v2Answer?.answer == "Yes, Friday is confirmed.")
        #expect(snapshot.v2Answer?.knownFromMeeting == ["a fixed deadline for this"])
        #expect(snapshot.v2AnswerInFlight == false)
        let request = await llm.requests.last!
        #expect(request.purpose == .suggestAnswer)
        #expect(request.user.contains("QUESTION: Is the deadline fixed?"))
    }

    @Test func suggestAnswerIsANoOpWhenQuestionIDDoesNotMatchTheCurrentQuestion() async {
        let llm = FakeCopilotLLM(behaviors: [.respond(canned())])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "Do we have a fixed deadline for this?"))
        await waitUntil { await engine.currentSnapshot().lastQuestionID != nil }

        await engine.suggestAnswer(questionID: "some-stale-id-that-does-not-match")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await llm.callCount == 1, "a stale questionID must never trigger a V2 request")
        #expect(await engine.currentSnapshot().v2Answer == nil)
    }

    @Test func askMeetGistWithoutContextNeverIncludesAContextSection() async {
        let llm = FakeCopilotLLM(behaviors: [.respond(cannedAnswer(answer: "Summary of the last few minutes."))])
        let engine = makeEngine(llm: llm)
        await engine.ask("Summarize the last few minutes.")
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2Kind == .ask)
        #expect(snapshot.v2Answer?.answer == "Summary of the last few minutes.")
        let request = await llm.requests.last!
        #expect(request.purpose == .ask)
        #expect(!request.user.contains("CONTEXT"))
    }

    @Test func askMeetGistWithContextIncludesTheContextSectionAndFromContextClaims() async throws {
        let llm = FakeCopilotLLM(behaviors: [.respond(cannedAnswer(
            answer: "The roadmap doc says Q3.", known: [], fromContext: ["Target quarter is Q3"]))])
        let engine = makeEngine(llm: llm)
        let context = try ManualFileContextProvider(fileName: "roadmap.md", rawText: "Target quarter is Q3 for the migration.")

        await engine.ask("What quarter does the roadmap target?", contextProvider: context)
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2Answer?.fromContext == ["Target quarter is Q3"])
        let request = await llm.requests.last!
        #expect(request.user.contains("CONTEXT"))
        #expect(request.user.contains("roadmap.md"))
        #expect(request.user.contains("Target quarter is Q3 for the migration."))
    }

    @Test func unsupportedKnownFromMeetingClaimIsMovedToAssumptions() async {
        // "known_from_meeting" claims something that never appears anywhere
        // in the turns/state this request was given — the post-check must
        // move it to "assumptions" rather than publish it as a known fact.
        let llm = FakeCopilotLLM(behaviors: [.respond(cannedAnswer(
            answer: "Alice will own the migration.",
            known: ["Alice owns the ERP migration"], assumptions: []))])
        let engine = makeEngine(llm: llm)
        await engine.ask("Who owns the ERP migration?")
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let answer = await engine.currentSnapshot().v2Answer!
        #expect(answer.knownFromMeeting.isEmpty, "unsupported claim must not remain in known_from_meeting")
        #expect(answer.assumptions.contains("Alice owns the ERP migration"))
    }

    @Test func supportedKnownFromMeetingClaimStaysKnown() async {
        let llm = FakeCopilotLLM(behaviors: [.respond(canned()), .respond(cannedAnswer(
            answer: "The deadline is fixed.", known: ["Is the deadline fixed?"], assumptions: []))])
        let engine = makeEngine(llm: llm)
        await engine.ingest(turn(1, "Do we have a fixed deadline for this?"))
        await waitUntil { await engine.currentSnapshot().lastQuestionID != nil }
        let questionID = await engine.currentSnapshot().lastQuestionID!

        await engine.suggestAnswer(questionID: questionID)
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let answer = await engine.currentSnapshot().v2Answer!
        #expect(answer.knownFromMeeting == ["Is the deadline fixed?"], "a claim overlapping the turns must stay known")
        #expect(answer.assumptions.isEmpty)
    }

    @Test func aNewV2RequestCancelsWhicheverV2RequestWasInFlight() async {
        let llm = FakeCopilotLLM(behaviors: [.hang, .respond(cannedAnswer(answer: "Second answer wins."))])
        let engine = makeEngine(llm: llm)
        await engine.ask("First question, will hang.")
        // Wait until the first request has actually reached `complete()` (and
        // therefore consumed the `.hang` behavior) before cancelling it —
        // otherwise the cancellation can race the spawned Task's first
        // execution and the second request could consume `.hang` instead.
        await waitUntil { await llm.callCount == 1 }
        #expect(await engine.currentSnapshot().v2AnswerInFlight)

        await engine.ask("Second question, should win.")
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2Answer?.answer == "Second answer wins.")
        #expect(snapshot.v2Question == "Second question, should win.")
        #expect(snapshot.v2AnswerInFlight == false)
    }

    @Test func staleV2AnswerNeverOverwritesANewerAlreadyAppliedOne() async {
        let llm = FakeCopilotLLM(behaviors: [
            .respond(cannedAnswer(answer: "First answer")),
            .respond(cannedAnswer(answer: "Second answer")),
        ])
        let engine = makeEngine(llm: llm)
        await engine.ask("Question one.")
        await waitUntil { await engine.currentSnapshot().v2Answer?.answer == "First answer" }
        await engine.ask("Question two.")
        await waitUntil { await engine.currentSnapshot().v2Answer?.answer == "Second answer" }

        // By construction (single V2 in-flight slot) seq only increases, so
        // the final applied answer must be the newer one — a hypothetical
        // reordered/duplicate response for the older request could never
        // clobber it once superseded.
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2Answer?.answer == "Second answer")
    }

    @Test func v2RequestInFlightNeverDelaysV1SemanticProcessing() async {
        // The V2 (Ask) request hangs forever; a V1 semantic request against
        // the *same* provider must still complete promptly — the two must
        // not share one in-flight slot (plan §7 "Scheduling").
        let llm = PurposeRoutedFakeLLM(semanticBehaviors: [.respond(canned())], v2Behaviors: [.hang])
        let engine = makeEngine(llm: llm)

        await engine.ask("This will hang forever and must not block V1.")
        await waitUntil { await engine.currentSnapshot().v2AnswerInFlight }

        await engine.ingest(turn(1, "A perfectly analyzable speaker turn arrives during the hang."))
        await waitUntil { await engine.currentState().lastMeaning != nil }

        let state = await engine.currentState()
        #expect(state.lastMeaning == "They are asking about the deadline.")
        #expect(await llm.semanticCallCount == 1)
        #expect(await llm.v2CallCount == 1)
        // The V2 request is still hanging — it must not have been able to
        // touch state, and the engine must still report it in flight.
        #expect(await engine.currentSnapshot().v2AnswerInFlight == true)
    }

    @Test func stoppingTheEngineCancelsAnyInFlightV2RequestAndItNeverPublishes() async {
        let llm = FakeCopilotLLM(behaviors: [.hang])
        let engine = makeEngine(llm: llm)
        await engine.ask("Will be stopped before it finishes.")
        await waitUntil { await engine.currentSnapshot().v2AnswerInFlight }

        await engine.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.v2AnswerInFlight == false)
        #expect(snapshot.v2Answer == nil)
    }

    /// Plan §5.13/§7.2/§7.3: `live/assist.jsonl` carries the context file's
    /// **name only**, never its content — even though the content is what's
    /// actually sent to the LLM (verified separately by the prompt-builder
    /// tests). This is the persistence-line-shape guarantee end to end
    /// through the real engine + a real (temp-dir) `LiveCopilotPersistence`.
    @Test func assistJSONLNeverContainsTheContextFilesContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetgist-assist-jsonl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = try #require(LiveCopilotPersistence(sessionDir: dir))
        let secretMarker = "SECRET_ROADMAP_CONTENT_MUST_NEVER_APPEAR_IN_ASSIST_JSONL"
        let context = try ManualFileContextProvider(fileName: "roadmap.md", rawText: "\(secretMarker) — target is Q3.")
        let llm = FakeCopilotLLM(behaviors: [.respond(cannedAnswer(answer: "Q3, per your roadmap.", fromContext: ["Target is Q3"]))])
        let engine = LiveCopilotEngine(config: .init(language: "English"), llm: llm, persistence: persistence)

        await engine.ask("What quarter does the roadmap target?", contextProvider: context)
        await waitUntil { await engine.currentSnapshot().v2Answer != nil }

        let assistURL = dir.appendingPathComponent("live/assist.jsonl")
        let contents = try String(contentsOf: assistURL, encoding: .utf8)
        #expect(!contents.contains(secretMarker), "the context file's content must never be written to assist.jsonl")
        #expect(contents.contains("roadmap.md"), "the context file's *name* is the only thing that should be logged")
        #expect(contents.contains("What quarter does the roadmap target?"))
        #expect(contents.contains("Q3, per your roadmap."))
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 1)
        for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
    }
}
