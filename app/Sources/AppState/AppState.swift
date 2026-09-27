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

/// Recording's live timer/mic/system-level readouts, updated at 10 Hz by
/// `AppState.startTicker()` (`AppState+Recording.swift`) while recording.
/// Kept on its own `ObservableObject` instead of as `@Published` properties on
/// `AppState` itself so the 10 Hz ticker only invalidates whichever small
/// subview declares `@ObservedObject var meters: RecordingMeters` (the
/// library status bar's timer, the menu bar popover's timer/levels, the mini
/// controller's timer/levels) — every other view observing `AppState`
/// (library list, detail, settings) no longer re-renders 10×/s. See
/// docs/review-2026-09-26.md P1 §1.
@MainActor
final class RecordingMeters: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Double = 0      // 0…1
    @Published var systemLevel: Double = 0   // 0…1
}

@MainActor
final class AppState: ObservableObject {
    // Recording
    @Published var state: RecState = .idle
    @Published var status = ""
    @Published var lastError: String?
    /// See `RecordingMeters`. Owned (not `@Published`) so updating it never
    /// fires `AppState.objectWillChange`.
    let meters = RecordingMeters()

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
    @Published var presence: Presence { didSet { defaults.set(presence.rawValue, forKey: Keys.presence) } }
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: Keys.auto) } }
    @Published var detectMeetings: Bool { didSet { defaults.set(detectMeetings, forKey: Keys.detectMeetings) } }
    @Published var autoGenerateNotes: Bool { didSet { defaults.set(autoGenerateNotes, forKey: Keys.autoGenerateNotes) } }
    @Published var postProcessEnabled: Bool { didSet { defaults.set(postProcessEnabled, forKey: Keys.postProcessEnabled) } }
    @Published var postProcessSource: String { didSet { defaults.set(postProcessSource, forKey: Keys.postProcessSource) } }
    @Published var useTemplate: Bool { didSet { defaults.set(useTemplate, forKey: Keys.useTemplate) } }
    @Published var notesTemplate: String { didSet { defaults.set(notesTemplate, forKey: Keys.template) } }
    /// Output language for generated Meeting Minutes/Summary, every notes
    /// provider (cloud and local). Defaults to Vietnamese regardless of the
    /// transcript's own language — Chinese transcripts still generate Chinese
    /// output (see `Prompts.polished`'s LANGUAGE rule), which takes precedence.
    @Published var notesLanguage: String { didSet { defaults.set(notesLanguage, forKey: Keys.notesLanguage) } }
    @Published var transcriptionProviderID: String { didSet { defaults.set(transcriptionProviderID, forKey: Keys.transcribe); refreshKeyFlag() } }
    @Published var notesProviderID: String { didSet { defaults.set(notesProviderID, forKey: Keys.notes); refreshKeyFlag() } }
    @Published var customProviders: [Provider] { didSet { saveCustom() } }
    @Published var offlineLanguage: String { didSet { defaults.set(offlineLanguage, forKey: Keys.offlineLanguage) } }
    @Published var offlineVocabulary: String { didSet { defaults.set(offlineVocabulary, forKey: Keys.offlineVocabulary) } }
    @Published var hasKeys = false

    /// Test seam: the `UserDefaults` domain every persisted setting reads from
    /// and writes to. Production default is `.standard`; tests inject a
    /// unique, empty suite (removed afterwards) so construction and settings
    /// round-trips never touch the user's real defaults. See `init`.
    /// `internal` (not `private`): read directly from `AppState+Providers.swift`
    /// (`effective`, `setModel`, `modelOverride`, `setCodexReasoningEffort`,
    /// `codexReasoningEffort`, `saveCustom`).
    let defaults: UserDefaults
    /// Test seam: how a provider's API key is looked up — `key(for:)` and
    /// `hasKey(_:)` (`AppState+Providers.swift`) call this instead of
    /// `Keychain.get` directly, so tests can supply fake keys without touching
    /// the real Keychain. Production default is the real Keychain lookup.
    let keyLookup: (String) -> String?
    /// Test seam: builds the cloud pipeline `processCloud` drives. Production
    /// default is the real `Pipelines.make`, which talks to actual cloud
    /// providers; tests substitute a fake `MeetingPipeline` (e.g. one that
    /// blocks until released, or fails at the notes stage) instead.
    var pipelineFactory: (_ transcription: Provider, _ transcriptionKey: String?,
                          _ notes: Provider, _ notesKey: String?,
                          _ notesTemplate: String?, _ notesLanguage: String?) throws -> MeetingPipeline
        = Pipelines.make
    /// Test seam: builds the `NotesWriter` used by `generateMinutesStage`
    /// (standalone Generate/Regenerate, and the notes half of the offline
    /// path). Production default is the real `Pipelines.makeNotesWriter`;
    /// tests substitute a fake `NotesWriter`; the writer then runs through
    /// `MeetingProcessor.generateNotes(sessionDir:writer:providerName:progress:)`.
    var notesWriterFactory: (_ notes: Provider, _ notesKey: String?,
                             _ notesTemplate: String?, _ notesLanguage: String?) throws -> any NotesWriter
        = Pipelines.makeNotesWriter

    let offlineRuntime: OfflineRuntimeManager
    lazy var offlineCoordinator = OfflineJobCoordinator(runtime: offlineRuntime, workerResourceName: "offline_worker")
    let qwenASRRuntime: Qwen3ASRRuntimeManager
    lazy var qwenASRCoordinator = OfflineJobCoordinator(runtime: qwenASRRuntime, workerResourceName: "offline_worker_qwen")
    let localNotesRuntime: LocalNotesRuntimeManager
    private var managerCancellables = Set<AnyCancellable>()

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
    /// launch, before `MeetGistApp.setup()` runs). `internal` (not `private`):
    /// called from every `AppState+*` extension file.
    func tr(_ s: LStr) -> String { loc?.t(s) ?? s.en }

    @Published var processStep = 0   // 0 = transcribing, 1 = summarizing
    /// The in-flight cloud/offline/notes/post-process job, if any. `internal`
    /// (not `private`): started/cancelled from `AppState+Processing.swift`,
    /// cancelled-and-awaited from `AppState+Recording.swift` (`startRecording`)
    /// and `AppState+Runtimes.swift` (`removeLocalNotesRuntime`).
    var processTask: Task<Void, Never>?
    /// `internal`: set from `AppState+Recording.swift` and
    /// `AppState+Processing.swift`.
    var localNotesTaskActive = false
    /// Bumped by `nextProcessGeneration()` (`AppState+Processing.swift`)
    /// whenever a new recording start or an explicit cancel makes the
    /// currently in-flight `processTask` stale. Every completion/catch path
    /// that mutates `state`/`status`/`lastError`/`processStep`/`hud` first
    /// checks its captured token against this so a job that hasn't noticed
    /// cancellation yet can never stomp whatever replaced it (recording, or a
    /// newer job) — see P0-2. `internal`: read from `AppState+Recording.swift`.
    var processGeneration = 0
    /// `internal` (not `private`): read/set from `AppState+Recording.swift`
    /// (start/stop/pause/ticker) and guarded against from
    /// `AppState+Processing.swift`/`AppState+Library.swift` (a recording in
    /// progress blocks offline processing, Generate, and import).
    var recorder: SessionRecorder?
    /// `internal`: only `AppState+Recording.swift` reads/writes this, but it's
    /// a stored property and must live on the main declaration.
    var ticker: AnyCancellable?
    var startDate: Date?
    var pausedAccum: TimeInterval = 0
    var pauseStart: Date?

    /// UserDefaults key names, and per-provider key builders. `internal` (not
    /// `private`): `AppState+Providers.swift` builds/reads keys via
    /// `Keys.modelOverride`/`Keys.codexEffort`/`Keys.custom`.
    enum Keys {
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

    /// - Parameters:
    ///   - userDefaults: Domain for every persisted setting. Production
    ///     default `.standard`; tests pass a unique, empty suite so
    ///     construction and settings round-trips can't touch (or be affected
    ///     by) the user's real defaults.
    ///   - initialOutputDir: Used in place of `~/Documents/meetgist` only when
    ///     `userDefaults` has no previously persisted output dir — i.e. it
    ///     replaces today's hardcoded fallback, it never overrides an
    ///     explicit user setting. Tests pass a temp dir so `init` never
    ///     creates or scans the real `~/Documents/meetgist`.
    ///   - keyLookup: How `key(for:)`/`hasKey(_:)` resolve a provider's API
    ///     key. Production default is the real Keychain; tests supply fake
    ///     keys.
    ///   - offlineRuntime, qwenASRRuntime, localNotesRuntime: Runtime managers
    ///     for the app-managed local engines. Production default constructs
    ///     each with its real Application Support root; tests can pass
    ///     instances pointed at a temp root (each manager's `init(root:)`)
    ///     instead. Either way, construction only reads state (`refresh()`);
    ///     it never installs or removes anything.
    init(userDefaults: UserDefaults = .standard,
         initialOutputDir: URL? = nil,
         keyLookup: @escaping (String) -> String? = Keychain.get,
         offlineRuntime: OfflineRuntimeManager? = nil,
         qwenASRRuntime: Qwen3ASRRuntimeManager? = nil,
         localNotesRuntime: LocalNotesRuntimeManager? = nil) {
        self.defaults = userDefaults
        self.keyLookup = keyLookup
        self.offlineRuntime = offlineRuntime ?? OfflineRuntimeManager()
        self.qwenASRRuntime = qwenASRRuntime ?? Qwen3ASRRuntimeManager()
        self.localNotesRuntime = localNotesRuntime ?? LocalNotesRuntimeManager()
        let d = userDefaults, fm = FileManager.default
        if let s = d.string(forKey: Keys.output) { outputDir = URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        else { outputDir = initialOutputDir ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/meetgist") }
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
        self.offlineRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        offlineCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        self.qwenASRRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        qwenASRCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        self.localNotesRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        // refresh() and each coordinator's scan() do synchronous disk I/O per
        // session folder that scales with meeting count; both hop off the
        // main actor internally so launch shows the window immediately instead
        // of blocking on however many meetings exist.
        refresh()
        scanOfflineCoordinators()
    }

    private func persistOutput() {
        defaults.set(outputDir.path, forKey: Keys.output)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
}
