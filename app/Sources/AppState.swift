// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import SwiftUI
import MeetGistKit

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var processing = false
    @Published var status = "Ready."
    @Published var meetings: [Meeting] = []
    @Published var selectedID: Meeting.ID?

    @Published var outputDir: URL { didSet { persist(\.outputDir, outputDir.path, Keys.output); refresh() } }
    @Published var transcriptionProviderID: String { didSet { UserDefaults.standard.set(transcriptionProviderID, forKey: Keys.transcribe); refreshKeyFlag() } }
    @Published var notesProviderID: String { didSet { UserDefaults.standard.set(notesProviderID, forKey: Keys.notes); refreshKeyFlag() } }
    @Published var customProviders: [Provider] { didSet { saveCustom() } }
    @Published var hasKeys: Bool = false

    private var recorder: SessionRecorder?

    private enum Keys {
        static let output = "MeetGistOutputDir"
        static let transcribe = "MeetGistTranscribeProvider"
        static let notes = "MeetGistNotesProvider"
        static let custom = "MeetGistCustomProviders"
    }

    init() {
        let d = UserDefaults.standard
        let fm = FileManager.default
        if let saved = d.string(forKey: Keys.output) {
            outputDir = URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        } else {
            outputDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/meetgist")
        }
        transcriptionProviderID = d.string(forKey: Keys.transcribe) ?? "gemini"
        notesProviderID = d.string(forKey: Keys.notes) ?? "gemini"
        if let data = d.data(forKey: Keys.custom),
           let arr = try? JSONDecoder().decode([Provider].self, from: data) {
            customProviders = arr
        } else { customProviders = [] }
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        refresh()
        refreshKeyFlag()
    }

    // MARK: Providers

    var allProviders: [Provider] { ProviderCatalog.builtIn + customProviders }
    var transcriptionProviders: [Provider] { allProviders.filter { $0.canTranscribe } }
    var notesProviders: [Provider] { allProviders.filter { $0.canWriteNotes } }

    func provider(_ id: String) -> Provider? { allProviders.first { $0.id == id } }
    var transcriptionProvider: Provider { provider(transcriptionProviderID) ?? ProviderCatalog.builtIn[0] }
    var notesProvider: Provider { provider(notesProviderID) ?? ProviderCatalog.builtIn[0] }

    /// Apply per-provider model overrides stored in UserDefaults.
    func effective(_ p: Provider) -> Provider {
        var e = p
        let d = UserDefaults.standard
        if let m = d.string(forKey: "model.\(p.id).transcribe"), !m.isEmpty { e.transcribeModel = m }
        if let m = d.string(forKey: "model.\(p.id).notes"), !m.isEmpty { e.notesModel = m }
        return e
    }

    func key(for p: Provider) -> String? { Keychain.get(p.keyAccount) }
    func hasKey(_ p: Provider) -> Bool { Keychain.get(p.keyAccount) != nil }

    func saveKey(_ key: String, for p: Provider) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: p.keyAccount)
        refreshKeyFlag()
        status = hasKey(p) ? "\(p.name) key saved." : "\(p.name) key cleared."
    }

    func setModel(_ model: String, for p: Provider, slot: String) {
        let key = "model.\(p.id).\(slot)"
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
        objectWillChange.send()
    }

    func modelOverride(_ p: Provider, slot: String) -> String {
        UserDefaults.standard.string(forKey: "model.\(p.id).\(slot)") ?? ""
    }

    func addCustomProvider() {
        let id = "custom-\(customProviders.count + 1)-\(UInt8.random(in: 0...255))"
        customProviders.append(ProviderCatalog.newCustom(id: id))
    }
    func updateCustom(_ p: Provider) {
        if let i = customProviders.firstIndex(where: { $0.id == p.id }) { customProviders[i] = p }
    }
    func removeCustom(_ p: Provider) {
        customProviders.removeAll { $0.id == p.id }
        if transcriptionProviderID == p.id { transcriptionProviderID = "gemini" }
        if notesProviderID == p.id { notesProviderID = "gemini" }
    }

    private func refreshKeyFlag() {
        hasKeys = hasKey(transcriptionProvider) && hasKey(notesProvider)
    }
    private func saveCustom() {
        if let data = try? JSONEncoder().encode(customProviders) {
            UserDefaults.standard.set(data, forKey: Keys.custom)
        }
        refreshKeyFlag()
    }

    // MARK: Meetings

    func refresh() { meetings = MeetingStore.list(in: outputDir) }
    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }

    // MARK: Recording

    func toggleRecording() {
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    private func startRecording() async {
        do {
            let rec = try SessionRecorder(outputDir: outputDir)
            recorder = rec
            try await rec.start()
            isRecording = true
            status = "Recording…"
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        guard let rec = recorder else { return }
        status = "Finishing…"
        let dir = await rec.stop()
        recorder = nil
        isRecording = false
        refresh()
        selectedID = dir.lastPathComponent
        await process(dir)
    }

    func process(_ dir: URL) async {
        guard hasKeys else {
            status = "Recorded. Add an API key in Settings to generate notes."
            return
        }
        processing = true
        status = "Processing…"
        do {
            let tp = effective(transcriptionProvider)
            let np = effective(notesProvider)
            let pipeline = try Pipelines.make(
                transcription: tp, transcriptionKey: key(for: tp),
                notes: np, notesKey: key(for: np))
            _ = try await MeetingProcessor.process(sessionDir: dir, pipeline: pipeline) { msg in
                Task { @MainActor in self.status = msg }
            }
            status = "Notes ready."
            refresh()
        } catch {
            status = "Notes failed: \(error.localizedDescription)"
        }
        processing = false
    }

    func reprocessSelected() {
        guard let m = selectedMeeting else { return }
        Task { await process(m.dir) }
    }

    func setOutputDir(_ url: URL) { outputDir = url }

    private func persist<T>(_ keyPath: KeyPath<AppState, T>, _ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
}
