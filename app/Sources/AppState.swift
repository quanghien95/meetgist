// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import MeetGistKit

enum RecState: Equatable { case idle, recording, paused, processing, error }
enum Presence: String { case menuBar, mini }

enum HUDKind { case recording, stopped, processing, done, error }
struct HUDEvent { let kind: HUDKind; let text: String }

/// Which pipeline slot a per-provider model override applies to. Raw values
/// are exactly the strings already persisted in UserDefaults keys — do not
/// rename without a migration (see `AppState.Keys.modelOverride`).
enum ProviderModelSlot: String { case transcribe, notes }

/// Whether the selected notes provider can currently generate minutes, and the
/// exact user-visible strings to show when it can't. Keeping this the one
/// place that checks local-runtime/on-device readiness means
/// `canGenerateMinutes`, `setupRequiredStatus`, and `generateMinutes`'s error
/// branch can't drift from each other or from the switch over `NotesStyle`.
struct NotesReadiness {
    let isReady: Bool
    /// Message used by `setupRequiredStatus`.
    let setupMessage: String
    /// `status` used by `generateMinutes` when this provider isn't ready.
    let unavailableStatus: String
    /// `lastError` used by `generateMinutes` when this provider isn't ready;
    /// nil means leave `lastError` untouched (today's behavior for the
    /// key-requiring cloud styles).
    let unavailableError: String?
}

@MainActor
final class AppState: ObservableObject {
    // Recording
    @Published var state: RecState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Double = 0      // 0…1
    @Published var systemLevel: Double = 0   // 0…1
    @Published var status = ""
    @Published var lastError: String?

    // Library
    @Published var meetings: [Meeting] = []
    @Published var selectedID: Meeting.ID?
    @Published var showSettings = false
    @Published var isLoadingMeetings = false

    // Settings
    @Published var outputDir: URL {
        didSet {
            persistOutput(); refresh()
            scanOfflineCoordinators()
        }
    }
    @Published var presence: Presence { didSet { UserDefaults.standard.set(presence.rawValue, forKey: Keys.presence) } }
    @Published var autoTranscribe: Bool { didSet { UserDefaults.standard.set(autoTranscribe, forKey: Keys.auto) } }
    @Published var detectMeetings: Bool { didSet { UserDefaults.standard.set(detectMeetings, forKey: Keys.detectMeetings) } }
    @Published var autoGenerateNotes: Bool { didSet { UserDefaults.standard.set(autoGenerateNotes, forKey: Keys.autoGenerateNotes) } }
    @Published var postProcessEnabled: Bool { didSet { UserDefaults.standard.set(postProcessEnabled, forKey: Keys.postProcessEnabled) } }
    @Published var postProcessSource: String { didSet { UserDefaults.standard.set(postProcessSource, forKey: Keys.postProcessSource) } }
    @Published var useTemplate: Bool { didSet { UserDefaults.standard.set(useTemplate, forKey: Keys.useTemplate) } }
    @Published var notesTemplate: String { didSet { UserDefaults.standard.set(notesTemplate, forKey: Keys.template) } }
    /// Output language for generated Meeting Minutes/Summary, every notes
    /// provider (cloud and local). Defaults to Vietnamese regardless of the
    /// transcript's own language — Chinese transcripts still generate Chinese
    /// output (see `Prompts.polished`'s LANGUAGE rule), which takes precedence.
    @Published var notesLanguage: String { didSet { UserDefaults.standard.set(notesLanguage, forKey: Keys.notesLanguage) } }
    @Published var transcriptionProviderID: String { didSet { UserDefaults.standard.set(transcriptionProviderID, forKey: Keys.transcribe); refreshKeyFlag() } }
    @Published var notesProviderID: String { didSet { UserDefaults.standard.set(notesProviderID, forKey: Keys.notes); refreshKeyFlag() } }
    @Published var customProviders: [Provider] { didSet { saveCustom() } }
    @Published var offlineLanguage: String { didSet { UserDefaults.standard.set(offlineLanguage, forKey: Keys.offlineLanguage) } }
    @Published var offlineVocabulary: String { didSet { UserDefaults.standard.set(offlineVocabulary, forKey: Keys.offlineVocabulary) } }
    @Published var hasKeys = false

    lazy var offlineRuntime = OfflineRuntimeManager()
    lazy var offlineCoordinator = OfflineJobCoordinator(runtime: offlineRuntime, workerResourceName: "offline_worker")
    lazy var qwenASRRuntime = Qwen3ASRRuntimeManager()
    lazy var qwenASRCoordinator = OfflineJobCoordinator(runtime: qwenASRRuntime, workerResourceName: "offline_worker_qwen")
    lazy var localNotesRuntime = LocalNotesRuntimeManager()
    private var managerCancellables = Set<AnyCancellable>()

    /// The offline runtime/coordinator pair for the currently selected
    /// transcription provider. Each local engine (Whisper, Qwen3-ASR) has its
    /// own fully independent runtime and job coordinator, so switching the
    /// provider never mixes up install state or in-flight jobs between them.
    private var activeOfflineRuntime: any OfflineTranscriptionRuntime {
        transcriptionProviderID == ProviderCatalog.offlineQwen3ASRID ? qwenASRRuntime : offlineRuntime
    }
    var activeOfflineCoordinator: OfflineJobCoordinator {
        transcriptionProviderID == ProviderCatalog.offlineQwen3ASRID ? qwenASRCoordinator : offlineCoordinator
    }

    /// Scans both offline coordinators, excluding whichever session(s) are
    /// currently active on either one from BOTH scans — so, say, deleting an
    /// unrelated meeting (`moveMeetingToTrash`) can never race a scan against
    /// the folder either coordinator is actively transcribing into. See P0-5.
    private func scanOfflineCoordinators() {
        let active = Set([offlineCoordinator.activeSessionID, qwenASRCoordinator.activeSessionID].compactMap { $0 })
        offlineCoordinator.scan(outputDir: outputDir, excluding: active)
        qwenASRCoordinator.scan(outputDir: outputDir, excluding: active)
    }

    /// Set by the app so AppState can flash the HUD on transitions.
    var hud: ((HUDEvent) -> Void)?
    private var mini: MiniController?
    private var meetingDetector: MeetingDetector?
    private let meetingPrompt = MeetingDetectedController()
    /// AppState is not a View and has no `@EnvironmentObject` Localization of
    /// its own; `installMiniController(loc:)` is the one place the app hands
    /// it the live `Localization` instance (see `MeetGistApp.setup()`), so it
    /// is captured here for every status/lastError string this file sets.
    private var loc: Localization?
    func installMiniController(loc: Localization) {
        self.loc = loc
        if mini == nil { mini = MiniController(state: self, loc: loc) }
    }
    func installMeetingDetector() { if meetingDetector == nil { meetingDetector = MeetingDetector(state: self) } }
    func presentMeetingDetected(title: String) { meetingPrompt.present(state: self, title: title) }
    /// Localized text for a status/lastError string set from AppState. Falls
    /// back to English if `loc` hasn't been installed yet (a brief window at
    /// launch, before `MeetGistApp.setup()` runs).
    private func tr(_ s: LStr) -> String { loc?.t(s) ?? s.en }

    @Published var processStep = 0   // 0 = transcribing, 1 = summarizing
    private var processTask: Task<Void, Never>?
    private var localNotesTaskActive = false
    /// Bumped by `nextProcessGeneration()` whenever a new recording start or an
    /// explicit cancel makes the currently in-flight `processTask` stale. Every
    /// completion/catch path that mutates `state`/`status`/`lastError`/
    /// `processStep`/`hud` first checks its captured token against this so a
    /// job that hasn't noticed cancellation yet can never stomp whatever
    /// replaced it (recording, or a newer job) — see P0-2.
    private var processGeneration = 0
    @discardableResult
    private func nextProcessGeneration() -> Int {
        processGeneration += 1
        return processGeneration
    }
    private var recorder: SessionRecorder?
    private var ticker: AnyCancellable?
    private var startDate: Date?
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?

    private enum Keys {
        static let output = "MeetGistOutputDir", presence = "MeetGistPresence", auto = "MeetGistAutoTranscribe"
        static let transcribe = "MeetGistTranscribeProvider", notes = "MeetGistNotesProvider", custom = "MeetGistCustomProviders"
        static let useTemplate = "MeetGistUseTemplate", template = "MeetGistTemplate"
        static let notesLanguage = "MeetGistNotesLanguage"
        static let offlineLanguage = "MeetGistOfflineLanguage", offlineVocabulary = "MeetGistOfflineVocabulary"
        static let detectMeetings = "MeetGistDetectMeetings", postProcessEnabled = "MeetGistPostProcessEnabled", postProcessSource = "MeetGistPostProcessSource"
        static let autoGenerateNotes = "MeetGistAutoGenerateNotes"

        /// Per-provider model override key, e.g. "model.gemini.transcribe".
        /// Exact same string shape as before this was declared here — existing
        /// user settings must keep working.
        static func modelOverride(providerID: String, slot: ProviderModelSlot) -> String {
            "model.\(providerID).\(slot.rawValue)"
        }
        /// Codex CLI reasoning-effort override key, e.g. "model.codex-cli.notes-effort".
        static func codexEffort(providerID: String) -> String {
            "model.\(providerID).notes-effort"
        }
    }

    init() {
        let d = UserDefaults.standard, fm = FileManager.default
        if let s = d.string(forKey: Keys.output) { outputDir = URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        else { outputDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/meetgist") }
        presence = Presence(rawValue: d.string(forKey: Keys.presence) ?? "menuBar") ?? .menuBar
        autoTranscribe = (d.object(forKey: Keys.auto) as? Bool) ?? true
        detectMeetings = (d.object(forKey: Keys.detectMeetings) as? Bool) ?? true
        autoGenerateNotes = (d.object(forKey: Keys.autoGenerateNotes) as? Bool) ?? true
        postProcessEnabled = (d.object(forKey: Keys.postProcessEnabled) as? Bool) ?? false
        postProcessSource = d.string(forKey: Keys.postProcessSource) ?? "import os\n\n# Available values are in MEETGIST_* environment variables.\nprint(f\"Processed: {os.environ['MEETGIST_MEETING_TITLE']}\")\n"
        useTemplate = (d.object(forKey: Keys.useTemplate) as? Bool) ?? false
        notesTemplate = d.string(forKey: Keys.template) ?? ""
        notesLanguage = d.string(forKey: Keys.notesLanguage) ?? Prompts.defaultNotesLanguage
        transcriptionProviderID = d.string(forKey: Keys.transcribe) ?? "gemini"
        notesProviderID = d.string(forKey: Keys.notes) ?? "gemini"
        offlineLanguage = d.string(forKey: Keys.offlineLanguage) ?? "auto"
        offlineVocabulary = d.string(forKey: Keys.offlineVocabulary) ?? HotwordPresets.defaultKeywords
        if let data = d.data(forKey: Keys.custom), let arr = try? JSONDecoder().decode([Provider].self, from: data) { customProviders = arr }
        else { customProviders = [] }
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        refreshKeyFlag()
        offlineRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        offlineCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        qwenASRRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        qwenASRCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        localNotesRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        // refresh() and each coordinator's scan() do synchronous disk I/O per
        // session folder that scales with meeting count; both hop off the
        // main actor internally so launch shows the window immediately instead
        // of blocking on however many meetings exist.
        refresh()
        scanOfflineCoordinators()
    }

    // MARK: Providers (v1.1)
    var allProviders: [Provider] { ProviderCatalog.builtIn + customProviders }
    var transcriptionProviders: [Provider] { allProviders.filter { $0.canTranscribe } }
    var notesProviders: [Provider] { allProviders.filter { $0.canWriteNotes } }
    func provider(_ id: String) -> Provider? { allProviders.first { $0.id == id } }
    var transcriptionProvider: Provider { provider(transcriptionProviderID) ?? ProviderCatalog.builtIn[0] }
    var notesProvider: Provider { provider(notesProviderID) ?? ProviderCatalog.builtIn[0] }
    func effective(_ p: Provider) -> Provider {
        var e = p; let d = UserDefaults.standard
        if let m = d.string(forKey: Keys.modelOverride(providerID: p.id, slot: .transcribe)), !m.isEmpty { e.transcribeModel = m }
        if let m = d.string(forKey: Keys.modelOverride(providerID: p.id, slot: .notes)), !m.isEmpty { e.notesModel = m }
        if p.notesStyle == .codexCLI,
           let effort = d.string(forKey: Keys.codexEffort(providerID: p.id)), !effort.isEmpty {
            e.notesReasoningEffort = effort
        }
        return e
    }
    func key(for p: Provider) -> String? { Keychain.get(p.keyAccount) }
    func hasKey(_ p: Provider) -> Bool {
        !p.needsAPIKey || Keychain.get(p.keyAccount) != nil
    }
    func saveKey(_ k: String, for p: Provider) {
        do {
            try Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines), for: p.keyAccount)
        } catch {
            lastError = error.localizedDescription
            status = tr(L.couldNotSaveAPIKey)
        }
        refreshKeyFlag()
    }
    func setModel(_ m: String, for p: Provider, slot: ProviderModelSlot) {
        UserDefaults.standard.set(m.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: Keys.modelOverride(providerID: p.id, slot: slot))
        objectWillChange.send()
    }
    func modelOverride(_ p: Provider, slot: ProviderModelSlot) -> String {
        UserDefaults.standard.string(forKey: Keys.modelOverride(providerID: p.id, slot: slot)) ?? ""
    }
    func setCodexReasoningEffort(_ effort: String, for p: Provider) {
        UserDefaults.standard.set(effort, forKey: Keys.codexEffort(providerID: p.id))
        objectWillChange.send()
    }
    func codexReasoningEffort(for p: Provider) -> String {
        UserDefaults.standard.string(forKey: Keys.codexEffort(providerID: p.id)) ?? (p.notesReasoningEffort ?? "none")
    }
    // A UUID keeps every id unique regardless of how many custom providers
    // exist or have been removed; existing ids are untouched. See P3.
    func addCustomProvider() { customProviders.append(ProviderCatalog.newCustom(id: "custom-\(UUID().uuidString)")) }
    func updateCustom(_ p: Provider) { if let i = customProviders.firstIndex(where: { $0.id == p.id }) { customProviders[i] = p } }
    func removeCustom(_ p: Provider) { customProviders.removeAll { $0.id == p.id }; if transcriptionProviderID == p.id { transcriptionProviderID = "gemini" }; if notesProviderID == p.id { notesProviderID = "gemini" } }
    var usesOfflineTranscription: Bool { transcriptionProvider.transcribeStyle?.isLocal ?? false }
    var usesLocalNotes: Bool { notesProvider.notesStyle?.isOnDevice ?? false }
    var canStartTranscription: Bool {
        usesOfflineTranscription ? activeOfflineRuntime.state == .ready : hasKey(transcriptionProvider)
    }
    /// The one place that checks readiness for a notes style that depends on
    /// an app runtime manager (Local Qwen install state, Apple availability,
    /// Codex CLI installed) — `canGenerateMinutes`, `setupRequiredStatus`, and
    /// `generateMinutes`'s error branch all read from this instead of each
    /// re-implementing their own switch. No `default:` case, so adding a
    /// `NotesStyle` case forces updating this switch.
    private func notesReadiness(for provider: Provider) -> NotesReadiness {
        switch provider.notesStyle {
        case .apple:
            let availability = AppleFoundationModelsSupport.availability
            return NotesReadiness(isReady: availability.isReady,
                                   setupMessage: availability.message,
                                   unavailableStatus: tr(L.appleOnDeviceUnavailable),
                                   unavailableError: availability.message)
        case .qwenMLX:
            return NotesReadiness(isReady: localNotesRuntime.state == .ready,
                                   setupMessage: tr(L.installLocalQwenNotesSettings),
                                   unavailableStatus: tr(L.localQwenNotesNotInstalled),
                                   unavailableError: tr(L.installQwen3InSettings))
        case .codexCLI:
            return NotesReadiness(isReady: CodexCLIAvailability.isInstalled,
                                   setupMessage: tr(L.installCodexCLILogin),
                                   unavailableStatus: tr(L.codexCLIUnavailable),
                                   unavailableError: tr(L.installCodexCLILogin))
        case .gemini, .chat, nil:
            return NotesReadiness(isReady: hasKey(provider),
                                   setupMessage: tr(L.addKeyNotesProvider),
                                   unavailableStatus: tr(L.addKeyNotesProvider),
                                   unavailableError: nil)
        }
    }
    var canGenerateMinutes: Bool { notesReadiness(for: notesProvider).isReady }
    var offlineConfig: OfflineJobConfig {
        let (engine, model) = ProviderCatalog.offlineEngineConfig(for: transcriptionProviderID)
        return OfflineJobConfig(engine: engine, model: model, language: offlineLanguage, vocabulary: offlineVocabulary)
    }
    /// A meeting may have been transcribed by either local engine, independent
    /// of which one is currently selected — check both coordinators.
    func offlineJob(for meeting: Meeting) -> OfflineJobState? {
        offlineCoordinator.state(for: meeting.id) ?? qwenASRCoordinator.state(for: meeting.id)
    }
    private func refreshKeyFlag() { hasKeys = canStartTranscription && canGenerateMinutes }
    private var setupRequiredStatus: String {
        if !canStartTranscription { return tr(L.addKeyTranscriptionProvider) }
        return notesReadiness(for: notesProvider).setupMessage
    }
    private func saveCustom() { if let data = try? JSONEncoder().encode(customProviders) { UserDefaults.standard.set(data, forKey: Keys.custom) }; refreshKeyFlag() }

    // MARK: Meetings
    /// Scanning the output directory does synchronous disk I/O per session
    /// folder (existence checks, title file reads, resource values) that scales
    /// with meeting count. Run it off the main actor so it never blocks the UI,
    /// most importantly at launch.
    ///
    /// Cache-first: paint the last-known list from `.meetgist-cache.json`
    /// immediately (if present), then re-scan the real directory in the
    /// background and replace `meetings` + refresh the cache when it lands.
    /// This avoids a blank list for however long the full scan takes.
    func refresh() {
        let dir = outputDir
        if let cached = MeetingListCache.load(outputDir: dir) {
            meetings = cached
        }
        isLoadingMeetings = true
        Task.detached(priority: .userInitiated) {
            let list = MeetingStore.list(in: dir)
            MeetingListCache.save(list, outputDir: dir)
            await MainActor.run { [weak self] in
                guard let self, self.outputDir == dir else { return }
                self.meetings = list
                self.isLoadingMeetings = false
            }
        }
    }
    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }

    // MARK: Recording
    func toggleRecording() {
        switch state {
        case .idle, .error, .processing: Task { await startRecording() }
        case .recording, .paused: Task { await stopRecording() }
        }
    }

    func pauseResume() {
        guard let rec = recorder else { return }
        if state == .recording { rec.pause(); pauseStart = Date(); state = .paused; status = tr(L.paused) }
        else if state == .paused { rec.resume(); if let p = pauseStart { pausedAccum += Date().timeIntervalSince(p) }; pauseStart = nil; state = .recording; status = tr(L.statusRecording) }
    }

    private func startRecording() async {
        // Recording has absolute priority over any in-flight local/cloud job.
        // Bump the generation first so a job that hasn't noticed cancellation
        // yet can never mutate state on our behalf once it does finish.
        nextProcessGeneration()
        // Either local engine's coordinator could have an active job; stop its
        // subprocess directly (cancelling the Swift task alone doesn't stop it).
        if offlineCoordinator.activeSessionID != nil {
            await offlineCoordinator.stopForRecording()
        } else if qwenASRCoordinator.activeSessionID != nil {
            await qwenASRCoordinator.stopForRecording()
        }
        // Cancel and await ANY in-flight process task — cloud transcribe/notes,
        // notes-only generate/regenerate, or a post-process script run — so its
        // resources are released before a new SessionRecorder is constructed.
        if let task = processTask {
            task.cancel()
            await task.value
            processTask = nil
        }
        localNotesTaskActive = false
        // Request the permissions the recorders need, with MeetGist's usage strings,
        // before touching the capture APIs. Mic blocks on the user's choice; Screen
        // Recording prompts if needed (system audio stays empty until it's granted +
        // the app is relaunched, which the Settings → Privacy panel surfaces).
        _ = await Permissions.ensureMicrophone()
        _ = Permissions.ensureScreenRecording()
        do {
            let rec = try SessionRecorder(outputDir: outputDir)
            recorder = rec
            try await rec.start()
            startDate = Date(); pausedAccum = 0; pauseStart = nil; elapsed = 0
            state = .recording; status = tr(L.statusRecording); lastError = nil
            startTicker()
            hud?(HUDEvent(kind: .recording, text: "REC"))
        } catch {
            // A half-started recorder (e.g. system audio started, mic failed —
            // SessionRecorder.start() already stops system in that case) must
            // not stay referenced. See P0-6.
            recorder = nil
            state = .error; lastError = error.localizedDescription; status = tr(L.couldNotStart)
            hud?(HUDEvent(kind: .error, text: tr(L.error)))
        }
    }

    private func stopRecording() async {
        guard let rec = recorder else { return }
        stopTicker()
        status = tr(L.statusFinishing)
        let dir = await rec.stop()
        recorder = nil
        refresh(); selectedID = dir.lastPathComponent
        hud?(HUDEvent(kind: .stopped, text: tr(L.saved)))
        await finishNewSession(dir, savedMessage: tr(L.saved))
    }

    /// Shared "what happens after a new session's audio exists on disk" path,
    /// used by both recording (stopRecording) and audio import: kicks off
    /// auto-transcription per the user's settings, or reports why it didn't.
    private func finishNewSession(_ dir: URL, savedMessage: String) async {
        if usesOfflineTranscription {
            if autoTranscribe {
                if activeOfflineRuntime.state == .ready { process(dir) }
                else {
                    await activeOfflineCoordinator.markSetupRequired(sessionDir: dir, config: offlineConfig)
                    state = .idle; status = "\(savedMessage). \(tr(L.installLocalEngineSuffix))"
                }
            } else { state = .idle; status = "\(savedMessage)." }
        } else if hasKeys && autoTranscribe { process(dir) }
        else {
            state = .idle
            status = hasKeys ? "\(savedMessage)." : "\(savedMessage). \(setupRequiredStatus)"
        }
    }

    func process(_ dir: URL) {
        if usesOfflineTranscription { processOffline(dir); return }
        if usesLocalNotes, recorder != nil {
            lastError = tr(L.localNotesWhileRecordingError)
            status = tr(L.localNotesWhileRecordingStatus)
            return
        }
        processCloud(dir)
    }

    private func processCloud(_ dir: URL) {
        guard hasKeys else { state = .idle; status = "\(tr(L.recordedMessage)) \(setupRequiredStatus)"; return }
        processTask?.cancel()
        let generation = nextProcessGeneration()
        state = .processing; processStep = 0; status = tr(L.statusTranscribing)
        hud?(HUDEvent(kind: .processing, text: "…"))
        localNotesTaskActive = usesLocalNotes
        let jobStart = Date()
        processTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localNotesTaskActive = false }
            do {
                let tp = self.effective(self.transcriptionProvider), np = self.effective(self.notesProvider)
                let template = (self.useTemplate && !self.notesTemplate.isEmpty) ? self.notesTemplate : nil
                let pipeline = try Pipelines.make(transcription: tp, transcriptionKey: self.key(for: tp),
                                                  notes: np, notesKey: self.key(for: np),
                                                  notesTemplate: template, notesLanguage: self.notesLanguage)
                let generateNotes = self.autoGenerateNotes
                _ = try await MeetingProcessor.process(sessionDir: dir, pipeline: pipeline, generateNotes: generateNotes) { msg in
                    Task { @MainActor in
                        guard self.processGeneration == generation else { return }
                        self.status = msg
                        if msg.localizedCaseInsensitiveContains("minute") || msg.localizedCaseInsensitiveContains("summar") { self.processStep = 1 }
                    }
                }
                try Task.checkCancellation()
                guard self.processGeneration == generation else { return }
                self.refresh()
                if generateNotes { try await self.runPostProcessIfEnabled(for: dir, generation: generation) }
                guard self.processGeneration == generation else { return }
                self.state = .idle; self.status = generateNotes ? self.tr(L.notesReadyMessage) : self.tr(L.transcriptReadyMessage)
                self.hud?(HUDEvent(kind: .done, text: self.tr(L.done)))
            } catch is CancellationError {
                guard self.processGeneration == generation else { return }
                self.state = .idle; self.status = self.tr(L.canceledMessage)
            } catch let e as URLError where e.code == .cancelled {
                guard self.processGeneration == generation else { return }
                self.state = .idle; self.status = self.tr(L.canceledMessage)
            } catch {
                guard self.processGeneration == generation else { return }
                // Stage 1 (transcribe) writes transcript.md before stage 2 (notes)
                // ever runs (see MeetingProcessor.process). If that file exists
                // and was written by this job, the transcript survived and only
                // notes failed — surface that distinctly and refresh so the
                // meeting shows the transcript with a working Generate button.
                if Self.transcriptWasWritten(in: dir, after: jobStart) {
                    self.refresh()
                    self.state = .error; self.lastError = error.localizedDescription
                    self.status = self.tr(L.transcriptSavedNotesFailed)
                } else {
                    self.state = .error; self.lastError = error.localizedDescription; self.status = self.tr(L.notesFailedMessage)
                }
                self.hud?(HUDEvent(kind: .error, text: self.tr(L.failed)))
            }
        }
    }

    /// True if `transcript.md` exists and was (re)written after `since` — tells
    /// "transcription itself failed" apart from "the transcript was persisted
    /// but the notes stage after it failed" in `processCloud`'s error path.
    private static func transcriptWasWritten(in dir: URL, after since: Date) -> Bool {
        let url = dir.appendingPathComponent("transcript.md")
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        return mtime >= since
    }

    private func processOffline(_ dir: URL) {
        guard recorder == nil else {
            lastError = tr(L.localTranscriptionWhileRecordingError)
            status = tr(L.localTranscriptionWhileRecordingStatus)
            return
        }
        guard state != .processing else {
            status = tr(L.anotherProcessingRunning)
            return
        }
        if let active = offlineCoordinator.activeSessionID ?? qwenASRCoordinator.activeSessionID {
            status = active == dir.lastPathComponent
                ? tr(L.localTranscriptionAlreadyRunningThis)
                : tr(L.localTranscriptionAlreadyRunningOther)
            return
        }
        processTask?.cancel()
        let generation = nextProcessGeneration()
        state = .processing; processStep = 0; status = tr(L.localTranscriptionStarting)
        hud?(HUDEvent(kind: .processing, text: "…"))
        let coordinator = activeOfflineCoordinator
        processTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.start(sessionDir: dir, config: self.offlineConfig)
                while coordinator.activeSessionID != nil {
                    try Task.checkCancellation()
                    guard self.processGeneration == generation else { return }
                    if let job = coordinator.state(for: dir.lastPathComponent) {
                        let percent = Int(job.progress.fraction * 100)
                        self.status = self.tr(L.localTranscriptionPercent(percent))
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                try Task.checkCancellation()
                guard self.processGeneration == generation else { return }
                let job = coordinator.state(for: dir.lastPathComponent)
                switch job?.status {
                case .completed:
                    guard self.autoGenerateNotes else {
                        self.state = .idle; self.status = self.tr(L.transcriptReadyMessage)
                        self.refresh(); return
                    }
                    guard self.canGenerateMinutes else {
                        self.state = .idle; self.status = self.tr(L.transcriptReadyAddNotesProvider)
                        self.refresh(); return
                    }
                    self.processStep = 1; self.status = self.tr(L.writingMinutesSummary)
                    self.localNotesTaskActive = self.usesLocalNotes
                    try await self.generateMinutesStage(dir, generation: generation)
                    self.localNotesTaskActive = false
                    guard self.processGeneration == generation else { return }
                    self.refresh()
                    try await self.runPostProcessIfEnabled(for: dir, generation: generation)
                    guard self.processGeneration == generation else { return }
                    self.state = .idle; self.status = self.tr(L.notesReadyMessage)
                    self.hud?(HUDEvent(kind: .done, text: self.tr(L.done)))
                case .paused: self.state = .idle; self.status = self.tr(L.localTranscriptionPaused)
                case .canceled: self.state = .idle; self.status = self.tr(L.localTranscriptionCanceled)
                case .failed:
                    self.state = .error; self.lastError = job?.lastError; self.status = self.tr(L.localTranscriptionFailed)
                default: self.state = .idle; self.status = self.tr(L.localTranscriptionReadyToResume)
                }
            } catch is CancellationError {
                self.localNotesTaskActive = false
                // Recording startup owns the visible state after it requests stop.
            } catch {
                self.localNotesTaskActive = false
                guard self.processGeneration == generation else { return }
                self.state = .error; self.lastError = error.localizedDescription
                self.status = self.tr(L.localTranscriptionFailed)
            }
        }
    }

    func pauseOffline() { Task { await activeOfflineCoordinator.pause(); state = .idle; status = tr(L.localTranscriptionPaused) } }
    func resumeOffline(_ meeting: Meeting) { processOffline(meeting.dir) }
    func retryOffline(_ meeting: Meeting) { processOffline(meeting.dir) }
    func retranscribeOffline(_ meeting: Meeting) {
        guard activeOfflineRuntime.state == .ready else {
            state = .error
            lastError = OfflineCoordinatorError.runtimeNotReady.localizedDescription
            status = tr(L.localTranscriptionFailed)
            return
        }
        do {
            try activeOfflineCoordinator.resetTranscription(sessionDir: meeting.dir)
            processOffline(meeting.dir)
        } catch {
            state = .error; lastError = error.localizedDescription
            status = tr(L.localTranscriptionFailed)
        }
    }
    func cancelProcessing() {
        processTask?.cancel()
        let generation = nextProcessGeneration()
        if let active = [offlineCoordinator, qwenASRCoordinator].first(where: { $0.activeSessionID != nil }) {
            Task { [weak self] in
                await active.cancel()
                guard let self, self.processGeneration == generation else { return }
                self.state = .idle; self.status = self.tr(L.canceledMessage)
            }
        } else { state = .idle; status = tr(L.canceledMessage) }
    }

    func generateMinutes(_ dir: URL) {
        guard recorder == nil else {
            status = tr(L.stopRecordingBeforeGenerateNotes)
            return
        }
        guard canGenerateMinutes else {
            let readiness = notesReadiness(for: notesProvider)
            if let error = readiness.unavailableError { lastError = error }
            status = readiness.unavailableStatus
            return
        }
        processTask?.cancel()
        let generation = nextProcessGeneration()
        state = .processing; processStep = 1; status = tr(L.writingMinutesSummary)
        localNotesTaskActive = usesLocalNotes
        processTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localNotesTaskActive = false }
            do {
                try await self.generateMinutesStage(dir, generation: generation)
                try Task.checkCancellation()
                guard self.processGeneration == generation else { return }
                self.refresh()
                try await self.runPostProcessIfEnabled(for: dir, generation: generation)
                guard self.processGeneration == generation else { return }
                self.state = .idle; self.status = self.tr(L.minutesReadyMessage)
            } catch is CancellationError {
                guard self.processGeneration == generation else { return }
                self.state = .idle; self.status = self.tr(L.canceledMessage)
            } catch {
                guard self.processGeneration == generation else { return }
                self.state = .error; self.lastError = error.localizedDescription; self.status = self.tr(L.minutesFailedMessage)
            }
        }
    }

    private func generateMinutesStage(_ dir: URL, generation: Int) async throws {
        let provider = effective(notesProvider)
        let template = (useTemplate && !notesTemplate.isEmpty) ? notesTemplate : nil
        _ = try await MeetingProcessor.generateNotes(
            sessionDir: dir, notesProvider: provider, notesKey: key(for: provider),
            notesTemplate: template, notesLanguage: notesLanguage
        ) { [weak self] message in
            Task { @MainActor in
                guard let self, self.processGeneration == generation else { return }
                self.status = message
            }
        }
    }

    func runPostProcess(_ meeting: Meeting) {
        guard state != .processing else { status = tr(L.waitProcessingFinish); return }
        guard !postProcessSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = tr(L.addPythonCodeFirst); return
        }
        let generation = nextProcessGeneration()
        state = .processing; status = tr(L.runningPostProcessScript)
        processTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = self.postProcessSource
                // Run structurally inside processTask (not Task.detached, which
                // would drop cancellation) so cancelProcessing()/startRecording
                // can actually stop the child process. See P0-4.
                _ = try await PostProcessRunner.run(source: source, meeting: meeting)
                guard self.processGeneration == generation else { return }
                self.refresh(); self.state = .idle; self.status = self.tr(L.postProcessScriptFinished)
            } catch {
                guard self.processGeneration == generation else { return }
                self.state = .error; self.lastError = error.localizedDescription; self.status = self.tr(L.postProcessScriptFailed)
            }
        }
    }

    private func runPostProcessIfEnabled(for dir: URL, generation: Int) async throws {
        guard postProcessEnabled, !postProcessSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refresh()
        guard let meeting = meetings.first(where: { $0.dir == dir }) else { return }
        guard processGeneration == generation else { return }
        status = tr(L.runningPostProcessScript)
        let source = postProcessSource
        _ = try await PostProcessRunner.run(source: source, meeting: meeting)
        guard processGeneration == generation else { return }
        refresh()
    }

    func installOfflineRuntime() { Task { await offlineRuntime.install(); refreshKeyFlag() } }
    func removeOfflineRuntime() {
        Task {
            await offlineCoordinator.cancel()
            do { try offlineRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func installQwenASRRuntime() { Task { await qwenASRRuntime.install(); refreshKeyFlag() } }
    func removeQwenASRRuntime() {
        Task {
            await qwenASRCoordinator.cancel()
            do { try qwenASRRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func installLocalNotesRuntime() {
        Task { await localNotesRuntime.install(); refreshKeyFlag() }
    }
    func removeLocalNotesRuntime() {
        processTask?.cancel()
        Task {
            await processTask?.value
            do { try localNotesRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func reprocessSelected() { guard let m = selectedMeeting else { return }; process(m.dir) }

    // MARK: Import
    static let importableAudioTypes: [UTType] = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        .compactMap { $0 } + [UTType(filenameExtension: "flac")].compactMap { $0 }

    /// Opens a file picker for an existing audio recording and imports it as a
    /// new meeting, transcoding it into a fresh session folder so it behaves
    /// exactly like a recorded meeting from then on (transcribe, notes, rename…).
    func importAudio() {
        guard recorder == nil else {
            status = tr(L.stopRecordingBeforeImport)
            return
        }
        guard state != .processing else {
            status = tr(L.waitCurrentTaskBeforeImport)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.importableAudioTypes
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let dir = outputDir
        let name = "imported-\(Self.importFolderStamp())"
        let sessionDir = dir.appendingPathComponent(name)
        state = .processing; status = tr(L.importingMessage)
        Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                try await AudioTools.export(source, to: sessionDir.appendingPathComponent("mic.m4a"))
                self.refresh(); self.selectedID = sessionDir.lastPathComponent
                await self.finishNewSession(sessionDir, savedMessage: self.tr(L.importedMessage))
            } catch {
                self.state = .error; self.lastError = error.localizedDescription
                self.status = self.tr(L.importFailedMessage)
            }
        }
    }

    private static func importFolderStamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let day = df.string(from: Date())
        let seconds = Int(Date().timeIntervalSince1970)
        return "\(day)-\(seconds)"
    }
    func renameMeeting(_ meeting: Meeting, to title: String) {
        do {
            try MeetingStore.rename(meeting, to: title)
            refresh()
        } catch {
            lastError = error.localizedDescription
            status = tr(L.couldNotRenameMeeting)
        }
    }
    func moveMeetingToTrash(_ meeting: Meeting) {
        guard offlineCoordinator.activeSessionID != meeting.id, qwenASRCoordinator.activeSessionID != meeting.id else {
            lastError = tr(L.pauseOrCancelBeforeDelete)
            status = tr(L.meetingInUse)
            return
        }
        NSWorkspace.shared.recycle([meeting.dir]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.status = self.tr(L.couldNotMoveToTrash)
                    return
                }
                if self.selectedID == meeting.id { self.selectedID = nil }
                self.refresh()
                self.scanOfflineCoordinators()
                self.status = self.tr(L.meetingMovedToTrash)
            }
        }
    }
    func setOutputDir(_ url: URL) { outputDir = url }

    // MARK: Live timer + meters
    private func startTicker() {
        ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            if self.state == .recording {
                self.elapsed = Date().timeIntervalSince(start) - self.pausedAccum
                self.micLevel = Self.norm(self.recorder?.micLevel() ?? -160)
                Task { if let r = self.recorder { let s = await r.systemLevel(); self.systemLevel = Self.norm(s) } }
            }
        }
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil; micLevel = 0; systemLevel = 0 }
    static func norm(_ db: Float) -> Double { Double(max(0, min(1, (db + 60) / 60))) }

    private func persistOutput() {
        UserDefaults.standard.set(outputDir.path, forKey: Keys.output)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
}
