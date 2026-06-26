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

    @Published var outputDir: URL { didSet { persistOutputDir(); refresh() } }
    @Published var provider: ProviderID = .gemini
    @Published var model: String = GeminiPipeline.defaultModel
    @Published var hasKey: Bool = false

    private var recorder: SessionRecorder?
    private static let outputKey = "MeetGistOutputDir"
    private static let modelKey = "MeetGistModel"

    init() {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: Self.outputKey) {
            outputDir = URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        } else {
            outputDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/meetgist")
        }
        if let m = UserDefaults.standard.string(forKey: Self.modelKey), !m.isEmpty { model = m }
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        hasKey = Keychain.get(provider.keyAccount) != nil
        refresh()
    }

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
        guard hasKey else {
            status = "Recorded. Add an API key in Settings to generate notes."
            return
        }
        processing = true
        status = "Processing…"
        do {
            _ = try await MeetingProcessor.process(
                sessionDir: dir, provider: provider, model: model
            ) { msg in Task { @MainActor in self.status = msg } }
            status = "Notes ready."
            refresh()
        } catch {
            status = "Notes failed: \(error.localizedDescription)"
        }
        processing = false
    }

    /// Re-run the pipeline for an already-recorded meeting.
    func reprocessSelected() {
        guard let m = selectedMeeting else { return }
        Task { await process(m.dir) }
    }

    // MARK: Settings

    func saveKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keyAccount)
        hasKey = Keychain.get(provider.keyAccount) != nil
        status = hasKey ? "API key saved." : "API key cleared."
    }

    func saveModel(_ m: String) {
        model = m.isEmpty ? GeminiPipeline.defaultModel : m
        UserDefaults.standard.set(model, forKey: Self.modelKey)
    }

    private func persistOutputDir() {
        UserDefaults.standard.set(outputDir.path, forKey: Self.outputKey)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
}
