// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AppKit
import UniformTypeIdentifiers
import MeetGistKit

/// Published UI state for the Live Assist panel (plan §5.10–§5.12, §7).
/// Kept off `AppState` itself (same reasoning as `RecordingMeters`) so its
/// frequent per-turn updates only invalidate views that actually observe it.
@MainActor
final class LiveAssistState: ObservableObject {
    @Published var isActive = false
    @Published var snapshot = LiveAssistSnapshot()

    // MARK: - V2 (plan §7.3 manual project context)
    /// In-memory only for the current meeting (plan §7.3: "remembered only
    /// in memory") — never persisted beyond its file name in
    /// `live/assist.jsonl`. Cleared whenever a new recording starts.
    @Published var contextProvider: ManualFileContextProvider?
    /// Tracks the question a `suggestAnswer`/`ask` auto-trigger last saw, so
    /// `liveAutoSuggest` fires at most once per newly detected question
    /// (not once per snapshot).
    fileprivate var lastAutoSuggestedQuestionID: String?
}

// MARK: - Live Assist (V1 Live Meeting Copilot)
//
// Everything in this file must stay fully isolated from recording/
// transcription/notes (AGENTS.md invariant): a throw anywhere in this path
// only ever sets `liveAssist`/its own local state, and this file never
// writes `state`, `lastError`, `recorder`, `processTask`, or
// `processGeneration`.
extension AppState {
    /// Cloud notes providers only — Live Assist requires a cloud `CopilotLLM`
    /// (plan §3/§5.5); on-device providers (`.apple`, `.qwenMLX`) can't be
    /// picked here even though they're valid Notes providers.
    var liveAssistProviders: [Provider] {
        allProviders.filter {
            switch $0.notesStyle {
            case .gemini, .chat, .codexCLI: return true
            case .apple, .qwenMLX, nil: return false
            }
        }
    }

    /// Starts Live Assist for the just-started recording, in its own `Task`
    /// (called from `startRecording()` after `rec.start()` succeeded). Every
    /// failure surfaces only through `liveAssist.snapshot.status` — this
    /// function itself never throws out.
    func startLiveAssistIfEnabled(recorder: SessionRecorder, sessionDir: URL) {
        guard liveAssistEnabled else { return }
        liveAssistTask?.cancel()
        liveAssistSession = nil
        liveAssist.isActive = false
        liveAssist.snapshot = LiveAssistSnapshot()
        liveAssist.contextProvider = nil
        liveAssist.lastAutoSuggestedQuestionID = nil

        let engineConfig = LiveCopilotEngine.Config(language: notesLanguage, analyzeMic: liveAnalyzeMic)
        let persistence = LiveCopilotPersistence(sessionDir: sessionDir)
        let engine = LiveCopilotEngine(config: engineConfig, llm: resolveLiveLLM(), persistence: persistence)

        // Capture every setting this Task needs up front — it must not read
        // `self` again except through the weak reference below, so a
        // superseded/cancelled Task can never race a later recording's state.
        let logURL = persistence?.asrWorkerLogURL
        let language = liveTranscriptionLanguage
        let vocabulary = offlineVocabulary
        let runtime = liveASRRuntime
        let audioFactory = liveAudioSourceFactory
        let transcriberFactory = liveTranscriberFactory
        let anchorHostNs = recorder.recordingAnchorHostNs

        liveAssistTask = Task { [weak self] in
            var transcriber: (any RealtimeTranscriber)?
            do {
                transcriber = try transcriberFactory(runtime, language, vocabulary, logURL)
            } catch {
                await engine.setTranscriptionStatus(.liveASRNotInstalled)
            }
            guard !Task.isCancelled else { return }
            guard let transcriber else {
                // No ASR available: still publish engine snapshots (provider
                // status, "install Live ASR" status) even though no turns
                // will ever arrive — recording is entirely unaffected.
                await self?.observeLiveSnapshots(engine: engine)
                return
            }
            let (speaker, mic) = audioFactory(recorder)
            let sessionConfig = LiveAssistSession.Config(recordingAnchorHostNs: anchorHostNs)
            let session = LiveAssistSession(engine: engine, transcriber: transcriber,
                                            speakerSource: speaker, micSource: mic, config: sessionConfig)
            guard !Task.isCancelled, let self else { await session.stop(); return }
            self.liveAssistSession = session
            await session.start()
            guard !Task.isCancelled else { await session.stop(); return }
            await session.setLanguage(self.liveTranscriptionLanguage)
            self.liveAssist.isActive = true
            await self.observeLiveSnapshots(engine: engine)
        }
    }

    /// Applies to the next ASR request without reloading the model or clearing history.
    func liveTranscriptionLanguageDidChange() {
        guard let session = liveAssistSession else { return }
        let language = liveTranscriptionLanguage
        Task { await session.setLanguage(language) }
    }

    /// Stops Live Assist for the current recording — called at the very
    /// start of `stopRecording()` (before saving/processing) and when the
    /// user toggles Live Assist off mid-recording. A hard 2s cap so a slow
    /// worker/subprocess teardown never delays saving the recording's audio;
    /// teardown keeps running in the background past that cap regardless.
    func stopLiveAssist() async {
        guard liveAssistTask != nil || liveAssistSession != nil else { return }
        liveAssistTask?.cancel()
        liveAssistTask = nil
        let session = liveAssistSession
        liveAssistSession = nil
        liveAssist.isActive = false
        guard let session else { return }
        await Self.withDeadline(seconds: 2) { await session.stop() }
    }

    /// Toggles Live Assist on/off, including mid-recording (plan §5.11),
    /// without touching recording/processing in any way.
    func toggleLiveAssist() {
        liveAssistEnabled.toggle()
        guard let rec = recorder, state == .recording || state == .paused else { return }
        if liveAssistEnabled {
            startLiveAssistIfEnabled(recorder: rec, sessionDir: rec.sessionDir)
        } else {
            Task { await stopLiveAssist() }
        }
    }

    /// Forwarded from `pauseResume()` — Live Assist follows the recording's
    /// pause state (drops audio, finalizes any open segment) without
    /// affecting `rec`/`state` itself.
    func forwardPauseToLiveAssist(paused: Bool) {
        guard let session = liveAssistSession else { return }
        Task { paused ? await session.pause() : await session.resume() }
    }

    /// Stamps `ui_update` metrics (plan §5.9) the moment the panel actually
    /// renders the snapshot containing `turnID`. Best-effort: a missing
    /// session is a silent no-op.
    func stampLiveUIUpdate(turnID: Int) {
        guard let session = liveAssistSession else { return }
        Task { await session.recordUIUpdate(turnID: turnID) }
    }

    /// Called from `liveAssistProviderID`'s `didSet` and from `setModel` when
    /// the `.live` slot changes — swaps the running session's LLM without
    /// restarting audio/ASR (plan §5.11: provider/model can change mid-run).
    func liveAssistProviderDidChange() {
        guard let session = liveAssistSession else { return }
        let llm = resolveLiveLLM()
        Task { await session.setLLM(llm) }
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist / manual context) — plan §7

    /// The panel's "Suggest Answer" button — pressed only while
    /// `liveAssist.snapshot.lastQuestionID` is non-nil (the button is hidden
    /// otherwise). A silent no-op if there's no running session or no active
    /// question by the time this runs (stale-press protection lives in the
    /// engine itself, keyed on `questionID`).
    func suggestAnswer() {
        guard let session = liveAssistSession, let questionID = liveAssist.snapshot.lastQuestionID else { return }
        let context = liveAssist.contextProvider
        Task { await session.suggestAnswer(questionID: questionID, contextProvider: context) }
    }

    /// The panel's "Ask Meet Gist" text field submit action.
    func askMeetGist(_ question: String) {
        guard let session = liveAssistSession else { return }
        let context = liveAssist.contextProvider
        Task { await session.ask(question, contextProvider: context) }
    }

    /// "Context" picker (plan §7.3): one `.md`/`.txt` file via `NSOpenPanel`,
    /// read once, capped, kept in memory only for the current meeting. Runs
    /// on the main actor (like every other UI-triggered `AppState` action);
    /// the panel itself is synchronous/modal-less (`begin`), so this never
    /// blocks recording or Live Assist's own audio/ASR/LLM loops.
    func pickLiveContextFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                self.liveAssist.contextProvider = try ManualFileContextProvider(fileURL: url)
            } catch {
                self.liveAssist.snapshot.v2Error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func clearLiveContextFile() {
        liveAssist.contextProvider = nil
    }

    // MARK: - Private

    private func observeLiveSnapshots(engine: LiveCopilotEngine) async {
        for await snapshot in await engine.snapshots() {
            guard !Task.isCancelled else { return }
            liveAssist.snapshot = snapshot
            maybeAutoSuggest(for: snapshot)
        }
    }

    /// `liveAutoSuggest` (default off, plan §7.1): the moment a *new*
    /// question appears (a `lastQuestionID` this session hasn't already
    /// auto-triggered), press "Suggest Answer" on the user's behalf exactly
    /// once for that question — never re-fires for the same question on a
    /// later snapshot (e.g. after Live Notes update but the question is
    /// unchanged), and never fires for a question that was already active
    /// when Live Assist started re-observing (only a genuinely new id).
    private func maybeAutoSuggest(for snapshot: LiveAssistSnapshot) {
        guard liveAutoSuggest, let questionID = snapshot.lastQuestionID,
              liveAssist.lastAutoSuggestedQuestionID != questionID else { return }
        liveAssist.lastAutoSuggestedQuestionID = questionID
        suggestAnswer()
    }

    /// Resolves the provider Live Assist should use: `liveAssistProviderID`
    /// if set, else the Notes provider (only if it's a cloud provider — an
    /// on-device Notes provider selection must not silently pick a cloud
    /// provider Live Assist never asked for).
    private func resolveLiveProvider() -> Provider? {
        if !liveAssistProviderID.isEmpty { return provider(liveAssistProviderID) }
        let notes = notesProvider
        switch notes.notesStyle {
        case .gemini, .chat, .codexCLI: return notes
        case .apple, .qwenMLX, nil: return nil
        }
    }

    private func liveEffectiveProvider(_ base: Provider) -> Provider {
        var p = effective(base)
        if let override = defaults.string(forKey: Keys.modelOverride(providerID: base.id, slot: .live)),
           !override.isEmpty {
            p.notesModel = override
        }
        return p
    }

    private func resolveLiveLLM() -> (any CopilotLLM)? {
        guard let base = resolveLiveProvider() else { return nil }
        let p = liveEffectiveProvider(base)
        return try? copilotLLMFactory(p, key(for: p))
    }

    private static func withDeadline(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

/// Production factories for `AppState`'s `liveTranscriberFactory`/
/// `liveAudioSourceFactory` test seams — the only place app code builds a
/// real `QwenLiveTranscriber`/`LiveMicTap`/`SystemAudioLiveSource`.
enum LiveAssistFactories {
    @MainActor
    static func makeTranscriber(runtime: LiveASRRuntimeManager, language: String, vocabulary: String,
                                logURL: URL?) throws -> any RealtimeTranscriber {
        guard runtime.state == .ready else {
            throw PipelineError.unsupported("Install Live ASR in Settings to use Live Assist.")
        }
        let workerScriptURL = try QwenLiveTranscriber.resolveWorkerScriptURL()
        let config = QwenLiveTranscriber.Config(
            pythonURL: runtime.pythonURL,
            workerScriptURL: workerScriptURL,
            modelDirURL: runtime.modelURL,
            language: language,
            hotwordsFileURL: try? writeHotwordsFile(vocabulary),
            logURL: logURL)
        return QwenLiveTranscriber(config: config)
    }

    static func makeAudioSources(recorder: SessionRecorder) -> (speaker: any LiveAudioSource, mic: (any LiveAudioSource)?) {
        let speaker = SystemAudioLiveSource(setSink: { [weak recorder] sink in recorder?.setLiveSystemSink(sink) })
        return (speaker, LiveMicTap())
    }

    private static func writeHotwordsFile(_ vocabulary: String) throws -> URL? {
        let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-live-hotwords-\(UUID().uuidString).txt")
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
