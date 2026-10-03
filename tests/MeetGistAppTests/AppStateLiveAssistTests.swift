// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import MeetGistKit
@testable import MeetGistApp

/// Covers `AppState+LiveAssist`'s isolation contract (plan §5.11/§8): Live
/// Assist must never affect recording/processing, and every failure in its
/// own path must surface only through `liveAssist`, never `state`/
/// `lastError`/`recorder`/`processTask`/`processGeneration`. Real recording
/// (`SessionRecorder`/ScreenCaptureKit) can't run in a unit test, so these
/// tests only exercise `AppState`'s own book-keeping (settings, the
/// `startLiveAssistIfEnabled`/`stopLiveAssist` seams) — never a real
/// `SessionRecorder`.
@MainActor
@Suite struct AppStateLiveAssistTests {
    private struct FailingTranscriber: RealtimeTranscriber {
        let label = "failing"
        func prepare() async throws { throw FakeError(message: "prepare failed") }
        func transcribe(_ segment: SpeechSegment) async throws -> String { "" }
        func shutdown() async {}
    }

    private struct FakeLiveAudioSource: LiveAudioSource {
        func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws {}
        func stop() async {}
    }

    /// A `LiveAudioSource` the test can drive by hand — hands its `onChunk`
    /// callback out so the test can feed real (synthetic) PCM through the
    /// full endpointer/ASR/engine pipeline, the same pattern
    /// `LiveAssistSessionTests.swift`'s `FakeAudioSource` uses at the Kit
    /// level (duplicated here rather than shared since it's a different test
    /// target/module).
    private final class FeedableAudioSource: LiveAudioSource, @unchecked Sendable {
        private var onChunkCallback: (@Sendable (LivePCMChunk) -> Void)?
        func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws { onChunkCallback = onChunk }
        func stop() async {}
        func feed(seconds: Double, loud: Bool, startHostNs: UInt64) {
            guard let onChunkCallback else { return }
            let sampleRate = 16_000.0
            let count = Int(seconds * sampleRate)
            var samples = [Float](repeating: 0, count: count)
            if loud { for i in 0..<count { samples[i] = Float(sin(Double(i) * 0.6)) * 0.9 } }
            onChunkCallback(LivePCMChunk(samples: samples, sampleRate: sampleRate, channels: 1, hostTimeNs: startHostNs))
        }
    }

    /// A `RealtimeTranscriber` that always returns the same text — enough to
    /// drive a real segment through `LiveAssistSession`/`LiveCopilotEngine`
    /// without a real ASR worker.
    private struct FixedTextTranscriber: RealtimeTranscriber {
        let label = "fixed"
        let text: String
        func prepare() async throws {}
        func transcribe(_ segment: SpeechSegment) async throws -> String { text }
        func shutdown() async {}
    }

    /// A `CopilotLLM` that returns a canned semantic result (with an active
    /// question) for `.semantic` requests and a canned answer for V2
    /// (`.suggestAnswer`/`.ask`) requests — purpose-routed so the two request
    /// kinds never race for a shared call-order queue.
    private actor ScriptedLiveLLM: CopilotLLM {
        let label = "Scripted"
        let providerKind = "chat"
        private(set) var semanticCallCount = 0
        private(set) var v2CallCount = 0

        func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
            if request.purpose == .semantic {
                semanticCallCount += 1
                let json = """
                {"meaning": "They are asking if Friday works.", "speech_act": "question", "is_question": true,
                 "question": "Does Friday work?", "topic": "", "key_points": [], "decisions": [], "action_items": [],
                 "open_questions": [], "resolved_open_question_ids": []}
                """
                return CopilotLLMResponse(text: json, inputTokens: 5, outputTokens: 5, latency: 0.001, providerLabel: label)
            }
            v2CallCount += 1
            let json = """
            {"answer": "Yes, Friday works.", "known_from_meeting": [], "from_context": [],
             "assumptions": ["Inferred from context"], "confidence": "medium"}
            """
            return CopilotLLMResponse(text: json, inputTokens: 5, outputTokens: 5, latency: 0.001, providerLabel: label)
        }
    }

    private actor LanguageTrackingTranscriber: RealtimeTranscriber {
        nonisolated let label = "Language tracking"
        private(set) var language: String?
        private(set) var prepareCount = 0
        func prepare() async throws { prepareCount += 1 }
        func transcribe(_ segment: SpeechSegment) async throws -> String { "" }
        func setLanguage(_ language: String) async { self.language = language }
        func shutdown() async {}
    }

    @Test func liveLanguageDefaultsToEnglishAndChangesWithoutRestarting() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        #expect(state.liveTranscriptionLanguage == "en")
        state.offlineLanguage = "vi"
        state.liveAssistEnabled = true
        let transcriber = LanguageTrackingTranscriber()
        var factoryLanguage: String?
        state.liveTranscriberFactory = { _, language, _, _ in
            factoryLanguage = language
            return transcriber
        }
        state.liveAudioSourceFactory = { _ in (FakeLiveAudioSource(), nil) }
        let recorder = try SessionRecorder(outputDir: state.outputDir)
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await AppStateTestSupport.waitUntil { state.liveAssist.isActive }
        #expect(factoryLanguage == "en")
        state.liveTranscriptionLanguage = "auto"
        let deadline = Date().addingTimeInterval(2)
        while await transcriber.language != "auto", Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transcriber.language == "auto")
        #expect(state.defaults.string(forKey: "MeetGistLiveTranscriptionLanguage") == "auto")
        #expect(state.offlineLanguage == "vi")
        #expect(await transcriber.prepareCount == 1)
        await state.stopLiveAssist()
    }

    /// Disabled → none of the injected factories are ever called, and
    /// `liveAssist` stays inert. Exercises `startLiveAssistIfEnabled`
    /// directly, since real recording can't run headless in a test.
    @Test func disabledLiveAssistNeverCallsFactories() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        state.liveAssistEnabled = false

        final class CallFlag { var called = false }
        let transcriberCalled = CallFlag(), llmCalled = CallFlag(), audioCalled = CallFlag()
        state.liveTranscriberFactory = { _, _, _, _ in transcriberCalled.called = true; return FailingTranscriber() }
        state.copilotLLMFactory = { _, _ in llmCalled.called = true; throw FakeError(message: "should not be called") }
        state.liveAudioSourceFactory = { _ in audioCalled.called = true; return (FakeLiveAudioSource(), nil) }

        let dir = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-a")
        let recorder = try SessionRecorder(outputDir: state.outputDir)
        _ = dir // session dir isn't used when disabled
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!transcriberCalled.called)
        #expect(!llmCalled.called)
        #expect(!audioCalled.called)
        #expect(state.liveAssist.isActive == false)
    }

    /// Live Assist enabled but every injected factory throws: `state` must
    /// stay untouched by the live path (this test never drives recording, so
    /// it starts `.idle` and must remain `.idle`), and `liveAssist.snapshot`
    /// must reflect the failure instead of crashing/hanging anything.
    @Test func factoryFailuresNeverTouchAppStateOnlyLiveAssist() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        state.liveAssistEnabled = true
        state.liveAssistProviderID = "gemini"

        state.liveTranscriberFactory = { _, _, _, _ in throw FakeError(message: "no live ASR") }
        state.copilotLLMFactory = { _, _ in throw FakeError(message: "no key") }

        let recorder = try SessionRecorder(outputDir: state.outputDir)
        let stateBefore = state.state
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)

        try await AppStateTestSupport.waitUntil {
            state.liveAssist.snapshot.status == .liveASRNotInstalled
        }
        #expect(state.liveAssist.snapshot.status == .liveASRNotInstalled)
        #expect(state.state == stateBefore)
        #expect(state.lastError == nil)
        #expect(state.recorder == nil)
        #expect(state.processTask == nil)
    }

    /// The disabled-by-default setting is honored (plan §5.11): a fresh
    /// `AppState` has Live Assist off until the user turns it on.
    @Test func liveAssistDefaultsToDisabled() throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        #expect(state.liveAssistEnabled == false)
        #expect(state.liveAssistProviderID == "")
        #expect(state.liveAnalyzeMic == false)
    }

    /// `stopLiveAssist()` with nothing running is a harmless no-op — the
    /// recording-stop path always calls this unconditionally.
    @Test func stopLiveAssistWithNothingRunningIsANoOp() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        await state.stopLiveAssist()
        #expect(state.liveAssist.isActive == false)
    }

    /// A normal cloud processing job (fake pipeline) must proceed exactly as
    /// before with Live Assist enabled but failing — the isolation invariant
    /// from the other direction: Live Assist never blocks or alters
    /// processing.
    @Test func liveAssistFailureDoesNotBlockNormalProcessing() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        state.liveAssistEnabled = true
        state.liveTranscriberFactory = { _, _, _, _ in throw FakeError(message: "no live ASR") }
        let dir = try AppStateTestSupport.makeMeetingDir(in: state.outputDir, name: "meeting-a")
        state.pipelineFactory = { _, _, _, _, _, _ in
            FakePipeline(transcript: "[00:01] hello", notesResult: .success(("polished", "summary")))
        }

        state.process(dir)
        try await AppStateTestSupport.waitUntil { state.state == .idle }
        #expect(state.status == L.notesReadyMessage.en)
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist / auto-suggest / manual context) — plan §7

    /// `liveAutoSuggest` (plan §7.1) defaults off, same as `liveAssistEnabled`
    /// and `liveAnalyzeMic`.
    @Test func liveAutoSuggestDefaultsToOff() throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        #expect(state.liveAutoSuggest == false)
    }

    /// `suggestAnswer()`/`askMeetGist(_:)` with no running session must be
    /// harmless no-ops — the panel's buttons/field are hidden while Live
    /// Assist isn't running, but a stray call (e.g. a race during teardown)
    /// must never crash or touch unrelated `AppState`.
    @Test func suggestAnswerAndAskMeetGistAreNoOpsWithNoRunningSession() throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        state.suggestAnswer()
        state.askMeetGist("Anything?")
        #expect(state.liveAssist.snapshot.v2Answer == nil)
        #expect(state.state == .idle)
    }

    /// Full pipeline, real (fake-audio-driven) segments → ASR → semantic
    /// engine → a detected question — with `liveAutoSuggest` **off**
    /// (default), the question must appear but no V2 (Suggest Answer)
    /// request may ever fire on its own.
    @Test func autoSuggestDoesNotFireWhenSettingIsOff() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        state.liveAssistEnabled = true
        state.liveAutoSuggest = false
        state.liveAssistProviderID = "gemini"

        let llm = ScriptedLiveLLM()
        state.liveTranscriberFactory = { _, _, _, _ in FixedTextTranscriber(text: "Does Friday work for everyone?") }
        state.copilotLLMFactory = { _, _ in llm }
        let speaker = FeedableAudioSource()
        state.liveAudioSourceFactory = { _ in (speaker, nil) }

        let recorder = try SessionRecorder(outputDir: state.outputDir)
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await AppStateTestSupport.waitUntil { state.liveAssistSession != nil }

        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 1.0, loud: false, startHostNs: 2_000_000_000)

        try await AppStateTestSupport.waitUntil { state.liveAssist.snapshot.lastQuestionID != nil }
        // Give any (incorrect) auto-fire a chance to happen before asserting
        // it didn't.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await llm.v2CallCount == 0, "liveAutoSuggest is off — no V2 request may fire on its own")
        #expect(state.liveAssist.snapshot.v2Answer == nil)
    }

    /// Same pipeline with `liveAutoSuggest` **on**: the moment a new question
    /// is detected, `AppState` must press "Suggest Answer" on the user's
    /// behalf exactly once, and the resulting answer must reach
    /// `liveAssist.snapshot`.
    @Test func autoSuggestFiresExactlyOnceWhenANewQuestionAppears() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        state.liveAssistEnabled = true
        state.liveAutoSuggest = true
        state.liveAssistProviderID = "gemini"

        let llm = ScriptedLiveLLM()
        state.liveTranscriberFactory = { _, _, _, _ in FixedTextTranscriber(text: "Does Friday work for everyone?") }
        state.copilotLLMFactory = { _, _ in llm }
        let speaker = FeedableAudioSource()
        state.liveAudioSourceFactory = { _ in (speaker, nil) }

        let recorder = try SessionRecorder(outputDir: state.outputDir)
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await AppStateTestSupport.waitUntil { state.liveAssistSession != nil }

        speaker.feed(seconds: 1.0, loud: true, startHostNs: 1_000_000_000)
        speaker.feed(seconds: 1.0, loud: false, startHostNs: 2_000_000_000)

        try await AppStateTestSupport.waitUntil { state.liveAssist.snapshot.v2Answer != nil }
        #expect(state.liveAssist.snapshot.v2Answer?.answer == "Yes, Friday works.")
        #expect(await llm.v2CallCount == 1)

        // A later snapshot for the *same* question (e.g. a Live Notes update)
        // must not fire a second auto-suggest.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await llm.v2CallCount == 1, "auto-suggest must fire at most once per newly detected question")
    }

    /// `pickLiveContextFile`'s effect (a `ManualFileContextProvider` in
    /// `liveAssist.contextProvider`) must reach `ask`/`suggestAnswer` — this
    /// exercises that wiring directly (without going through the real
    /// `NSOpenPanel`, which needs a real window server) by setting the
    /// published property the panel would have set.
    @Test func contextProviderIsForwardedToAskMeetGist() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "fake-key" })
        defer { cleanup() }
        state.liveAssistEnabled = true
        state.liveAssistProviderID = "gemini"

        let llm = ScriptedLiveLLM()
        state.liveTranscriberFactory = { _, _, _, _ in FixedTextTranscriber(text: "irrelevant") }
        state.copilotLLMFactory = { _, _ in llm }
        state.liveAudioSourceFactory = { _ in (FakeLiveAudioSource(), nil) }

        let recorder = try SessionRecorder(outputDir: state.outputDir)
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await AppStateTestSupport.waitUntil { state.liveAssistSession != nil }

        state.liveAssist.contextProvider = try ManualFileContextProvider(fileName: "plan.md", rawText: "Q3 target.")
        state.askMeetGist("What quarter?")

        try await AppStateTestSupport.waitUntil { state.liveAssist.snapshot.v2Answer != nil }
        #expect(state.liveAssist.snapshot.v2Answer != nil)
    }

    /// Starting Live Assist for a new recording clears any manually selected
    /// context file from the previous meeting — it's in-memory-only,
    /// per-meeting state (plan §7.3), never carried across recordings.
    @Test func startingANewRecordingClearsThePreviousMeetingsContextFile() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        state.liveAssist.contextProvider = try ManualFileContextProvider(fileName: "old.md", rawText: "stale")
        state.liveAssistEnabled = true
        state.liveTranscriberFactory = { _, _, _, _ in throw FakeError(message: "no live ASR") }

        let recorder = try SessionRecorder(outputDir: state.outputDir)
        state.startLiveAssistIfEnabled(recorder: recorder, sessionDir: recorder.sessionDir)
        try await AppStateTestSupport.waitUntil { state.liveAssist.snapshot.status == .liveASRNotInstalled }

        #expect(state.liveAssist.contextProvider == nil)
    }
}
