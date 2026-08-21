// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import SwiftUI
import Combine
import AppKit
import MeetGistKit

enum RecState: Equatable { case idle, recording, paused, processing, error }
enum Presence: String { case menuBar, mini }

enum HUDKind { case recording, stopped, processing, done, error }
struct HUDEvent { let kind: HUDKind; let text: String }

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

    // Settings
    @Published var outputDir: URL { didSet { persistOutput(); refresh(); offlineCoordinator.scan(outputDir: outputDir) } }
    @Published var presence: Presence { didSet { UserDefaults.standard.set(presence.rawValue, forKey: Keys.presence) } }
    @Published var autoTranscribe: Bool { didSet { UserDefaults.standard.set(autoTranscribe, forKey: Keys.auto) } }
    @Published var useTemplate: Bool { didSet { UserDefaults.standard.set(useTemplate, forKey: Keys.useTemplate) } }
    @Published var notesTemplate: String { didSet { UserDefaults.standard.set(notesTemplate, forKey: Keys.template) } }
    @Published var transcriptionProviderID: String { didSet { UserDefaults.standard.set(transcriptionProviderID, forKey: Keys.transcribe); refreshKeyFlag() } }
    @Published var notesProviderID: String { didSet { UserDefaults.standard.set(notesProviderID, forKey: Keys.notes); refreshKeyFlag() } }
    @Published var customProviders: [Provider] { didSet { saveCustom() } }
    @Published var offlineLanguage: String { didSet { UserDefaults.standard.set(offlineLanguage, forKey: Keys.offlineLanguage) } }
    @Published var offlineVocabulary: String { didSet { UserDefaults.standard.set(offlineVocabulary, forKey: Keys.offlineVocabulary) } }
    @Published var hasKeys = false

    lazy var offlineRuntime = OfflineRuntimeManager()
    lazy var offlineCoordinator = OfflineJobCoordinator(runtime: offlineRuntime)
    private var managerCancellables = Set<AnyCancellable>()

    /// Set by the app so AppState can flash the HUD on transitions.
    var hud: ((HUDEvent) -> Void)?
    private var mini: MiniController?
    func installMiniController(loc: Localization) { if mini == nil { mini = MiniController(state: self, loc: loc) } }

    @Published var processStep = 0   // 0 = transcribing, 1 = summarizing
    private var processTask: Task<Void, Never>?
    private var recorder: SessionRecorder?
    private var ticker: AnyCancellable?
    private var startDate: Date?
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?

    private enum Keys {
        static let output = "MeetGistOutputDir", presence = "MeetGistPresence", auto = "MeetGistAutoTranscribe"
        static let transcribe = "MeetGistTranscribeProvider", notes = "MeetGistNotesProvider", custom = "MeetGistCustomProviders"
        static let useTemplate = "MeetGistUseTemplate", template = "MeetGistTemplate"
        static let offlineLanguage = "MeetGistOfflineLanguage", offlineVocabulary = "MeetGistOfflineVocabulary"
    }

    init() {
        let d = UserDefaults.standard, fm = FileManager.default
        if let s = d.string(forKey: Keys.output) { outputDir = URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        else { outputDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/meetgist") }
        presence = Presence(rawValue: d.string(forKey: Keys.presence) ?? "menuBar") ?? .menuBar
        autoTranscribe = (d.object(forKey: Keys.auto) as? Bool) ?? true
        useTemplate = (d.object(forKey: Keys.useTemplate) as? Bool) ?? false
        notesTemplate = d.string(forKey: Keys.template) ?? ""
        transcriptionProviderID = d.string(forKey: Keys.transcribe) ?? "gemini"
        notesProviderID = d.string(forKey: Keys.notes) ?? "gemini"
        offlineLanguage = d.string(forKey: Keys.offlineLanguage) ?? "auto"
        offlineVocabulary = d.string(forKey: Keys.offlineVocabulary) ?? ""
        if let data = d.data(forKey: Keys.custom), let arr = try? JSONDecoder().decode([Provider].self, from: data) { customProviders = arr }
        else { customProviders = [] }
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        refresh(); refreshKeyFlag()
        offlineRuntime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        offlineCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        offlineCoordinator.scan(outputDir: outputDir)
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
        if let m = d.string(forKey: "model.\(p.id).transcribe"), !m.isEmpty { e.transcribeModel = m }
        if let m = d.string(forKey: "model.\(p.id).notes"), !m.isEmpty { e.notesModel = m }
        return e
    }
    func key(for p: Provider) -> String? { Keychain.get(p.keyAccount) }
    func hasKey(_ p: Provider) -> Bool {
        p.transcribeStyle == "offline" || p.notesStyle == "apple" || Keychain.get(p.keyAccount) != nil
    }
    func saveKey(_ k: String, for p: Provider) { Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines), for: p.keyAccount); refreshKeyFlag() }
    func setModel(_ m: String, for p: Provider, slot: String) { UserDefaults.standard.set(m.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model.\(p.id).\(slot)"); objectWillChange.send() }
    func modelOverride(_ p: Provider, slot: String) -> String { UserDefaults.standard.string(forKey: "model.\(p.id).\(slot)") ?? "" }
    func addCustomProvider() { customProviders.append(ProviderCatalog.newCustom(id: "custom-\(customProviders.count + 1)-\(UInt8.random(in: 0...255))")) }
    func updateCustom(_ p: Provider) { if let i = customProviders.firstIndex(where: { $0.id == p.id }) { customProviders[i] = p } }
    func removeCustom(_ p: Provider) { customProviders.removeAll { $0.id == p.id }; if transcriptionProviderID == p.id { transcriptionProviderID = "gemini" }; if notesProviderID == p.id { notesProviderID = "gemini" } }
    var usesOfflineTranscription: Bool { transcriptionProvider.transcribeStyle == "offline" }
    var canStartTranscription: Bool {
        usesOfflineTranscription ? offlineRuntime.state == .ready : hasKey(transcriptionProvider)
    }
    var canGenerateMinutes: Bool {
        notesProvider.notesStyle == "apple"
            ? AppleFoundationModelsSupport.availability.isReady
            : hasKey(notesProvider)
    }
    var offlineConfig: OfflineJobConfig {
        OfflineJobConfig(language: offlineLanguage, vocabulary: offlineVocabulary)
    }
    func offlineJob(for meeting: Meeting) -> OfflineJobState? { offlineCoordinator.state(for: meeting.id) }
    private func refreshKeyFlag() { hasKeys = canStartTranscription && canGenerateMinutes }
    private func saveCustom() { if let data = try? JSONEncoder().encode(customProviders) { UserDefaults.standard.set(data, forKey: Keys.custom) }; refreshKeyFlag() }

    // MARK: Meetings
    func refresh() { meetings = MeetingStore.list(in: outputDir) }
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
        if state == .recording { rec.pause(); pauseStart = Date(); state = .paused; status = "Paused" }
        else if state == .paused { rec.resume(); if let p = pauseStart { pausedAccum += Date().timeIntervalSince(p) }; pauseStart = nil; state = .recording; status = "Recording…" }
    }

    private func startRecording() async {
        // Recording has absolute priority over the local worker. Cancellation of
        // the active Swift task prevents its completion handler racing recording.
        processTask?.cancel()
        await offlineCoordinator.stopForRecording()
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
            state = .recording; status = "Recording…"; lastError = nil
            startTicker()
            hud?(HUDEvent(kind: .recording, text: "REC"))
        } catch {
            state = .error; lastError = error.localizedDescription; status = "Couldn't start"
            hud?(HUDEvent(kind: .error, text: "Error"))
        }
    }

    private func stopRecording() async {
        guard let rec = recorder else { return }
        stopTicker()
        status = "Finishing…"
        let dir = await rec.stop()
        recorder = nil
        refresh(); selectedID = dir.lastPathComponent
        hud?(HUDEvent(kind: .stopped, text: "Saved"))
        if autoTranscribe {
            if usesOfflineTranscription {
                if offlineRuntime.state == .ready { process(dir) }
                else {
                    await offlineCoordinator.markSetupRequired(sessionDir: dir, config: offlineConfig)
                    state = .idle; status = "Saved. Install Local Whisper in Settings to transcribe."
                }
            } else if hasKeys { process(dir) }
            else { state = .idle; status = "Saved. Add API keys in Settings to generate notes." }
        } else { state = .idle; status = "Saved." }
    }

    func process(_ dir: URL) {
        if usesOfflineTranscription { processOffline(dir); return }
        processCloud(dir)
    }

    private func processCloud(_ dir: URL) {
        guard hasKeys else { state = .idle; status = "Recorded. Add an API key in Settings."; return }
        processTask?.cancel()
        state = .processing; processStep = 0; status = "Transcribing…"
        hud?(HUDEvent(kind: .processing, text: "…"))
        processTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tp = self.effective(self.transcriptionProvider), np = self.effective(self.notesProvider)
                let template = (self.useTemplate && !self.notesTemplate.isEmpty) ? self.notesTemplate : nil
                let pipeline = try Pipelines.make(transcription: tp, transcriptionKey: self.key(for: tp),
                                                  notes: np, notesKey: self.key(for: np),
                                                  notesTemplate: template)
                _ = try await MeetingProcessor.process(sessionDir: dir, pipeline: pipeline) { msg in
                    Task { @MainActor in
                        self.status = msg
                        if msg.localizedCaseInsensitiveContains("minute") || msg.localizedCaseInsensitiveContains("summar") { self.processStep = 1 }
                    }
                }
                try Task.checkCancellation()
                self.state = .idle; self.status = "Notes ready."; self.refresh()
                self.hud?(HUDEvent(kind: .done, text: "Done"))
            } catch is CancellationError {
                self.state = .idle; self.status = "Canceled."
            } catch let e as URLError where e.code == .cancelled {
                self.state = .idle; self.status = "Canceled."
            } catch {
                self.state = .error; self.lastError = error.localizedDescription; self.status = "Notes failed"
                self.hud?(HUDEvent(kind: .error, text: "Failed"))
            }
        }
    }

    private func processOffline(_ dir: URL) {
        processTask?.cancel()
        state = .processing; processStep = 0; status = "Starting local transcription…"
        hud?(HUDEvent(kind: .processing, text: "…"))
        processTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.offlineCoordinator.start(sessionDir: dir, config: self.offlineConfig)
                while self.offlineCoordinator.activeSessionID != nil {
                    try Task.checkCancellation()
                    if let job = self.offlineCoordinator.state(for: dir.lastPathComponent) {
                        let percent = Int(job.progress.fraction * 100)
                        self.status = "Local transcription \(percent)%"
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                try Task.checkCancellation()
                let job = self.offlineCoordinator.state(for: dir.lastPathComponent)
                switch job?.status {
                case .completed:
                    self.state = .idle; self.status = "Transcript ready."
                    self.refresh(); self.hud?(HUDEvent(kind: .done, text: "Done"))
                case .paused: self.state = .idle; self.status = "Local transcription paused."
                case .canceled: self.state = .idle; self.status = "Local transcription canceled."
                case .failed:
                    self.state = .error; self.lastError = job?.lastError; self.status = "Local transcription failed"
                default: self.state = .idle; self.status = "Local transcription ready to resume."
                }
            } catch is CancellationError {
                // Recording startup owns the visible state after it requests stop.
            } catch {
                self.state = .error; self.lastError = error.localizedDescription
                self.status = "Local transcription failed"
            }
        }
    }

    func pauseOffline() { Task { await offlineCoordinator.pause(); state = .idle; status = "Local transcription paused." } }
    func resumeOffline(_ meeting: Meeting) { processOffline(meeting.dir) }
    func retryOffline(_ meeting: Meeting) { processOffline(meeting.dir) }
    func retranscribeOffline(_ meeting: Meeting) {
        guard offlineRuntime.state == .ready else {
            state = .error
            lastError = OfflineCoordinatorError.runtimeNotReady.localizedDescription
            status = "Local transcription failed"
            return
        }
        do {
            try offlineCoordinator.resetTranscription(sessionDir: meeting.dir)
            processOffline(meeting.dir)
        } catch {
            state = .error; lastError = error.localizedDescription
            status = "Local transcription failed"
        }
    }
    func cancelProcessing() {
        processTask?.cancel()
        if offlineCoordinator.activeSessionID != nil {
            Task { await offlineCoordinator.cancel(); state = .idle; status = "Canceled." }
        } else { state = .idle; status = "Canceled." }
    }

    func generateMinutes(_ dir: URL) {
        guard canGenerateMinutes else {
            if notesProvider.notesStyle == "apple" {
                let availability = AppleFoundationModelsSupport.availability
                lastError = availability.message
                status = "Apple On-Device is unavailable."
            } else {
                status = "Add an API key for the Notes provider."
            }
            return
        }
        processTask?.cancel()
        state = .processing; processStep = 1; status = "Writing minutes & summary…"
        processTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = self.effective(self.notesProvider)
                let template = (self.useTemplate && !self.notesTemplate.isEmpty) ? self.notesTemplate : nil
                _ = try await MeetingProcessor.generateNotes(
                    sessionDir: dir, notesProvider: provider, notesKey: self.key(for: provider),
                    notesTemplate: template) { message in
                        Task { @MainActor in self.status = message }
                    }
                try Task.checkCancellation()
                self.state = .idle; self.status = "Minutes ready."; self.refresh()
            } catch is CancellationError {
                self.state = .idle; self.status = "Canceled."
            } catch {
                self.state = .error; self.lastError = error.localizedDescription; self.status = "Minutes failed"
            }
        }
    }

    func installOfflineRuntime() { Task { await offlineRuntime.install(); refreshKeyFlag() } }
    func removeOfflineRuntime() {
        Task {
            await offlineCoordinator.cancel()
            do { try offlineRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func reprocessSelected() { guard let m = selectedMeeting else { return }; process(m.dir) }
    func renameMeeting(_ meeting: Meeting, to title: String) {
        do {
            try MeetingStore.rename(meeting, to: title)
            refresh()
        } catch {
            lastError = error.localizedDescription
            status = "Could not rename meeting."
        }
    }
    func moveMeetingToTrash(_ meeting: Meeting) {
        guard offlineCoordinator.activeSessionID != meeting.id else {
            lastError = "Pause or cancel transcription before deleting this meeting."
            status = "Meeting is in use."
            return
        }
        NSWorkspace.shared.recycle([meeting.dir]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.status = "Could not move meeting to Trash."
                    return
                }
                if self.selectedID == meeting.id { self.selectedID = nil }
                self.refresh()
                self.offlineCoordinator.scan(outputDir: self.outputDir)
                self.status = "Meeting moved to Trash."
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
