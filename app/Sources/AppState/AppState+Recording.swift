// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import Combine
import MeetGistKit

// MARK: - Recording
extension AppState {
    func toggleRecording() {
        switch state {
        case .idle, .error, .processing: Task { await startRecording() }
        case .recording, .paused: Task { await stopRecording() }
        }
    }

    func pauseResume() {
        guard let rec = recorder else { return }
        if state == .recording {
            rec.pause(); meters.micLevel = 0; meters.systemLevel = 0; pauseStart = Date(); state = .paused; status = tr(L.paused)
            forwardPauseToLiveAssist(paused: true)
        } else if state == .paused {
            rec.resume(); if let p = pauseStart { pausedAccum += Date().timeIntervalSince(p) }; pauseStart = nil; state = .recording; status = tr(L.statusRecording)
            forwardPauseToLiveAssist(paused: false)
        }
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
            startDate = Date(); pausedAccum = 0; pauseStart = nil; meters.elapsed = 0
            state = .recording; status = tr(L.statusRecording); lastError = nil
            startTicker()
            hud?(HUDEvent(kind: .recording, text: "REC"))
            // Own path, own failures (plan §5.11): never touches `state`/
            // `lastError`/`recorder` — any problem only sets `liveAssist`.
            startLiveAssistIfEnabled(recorder: rec, sessionDir: rec.sessionDir)
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
        // Live Assist stops first (hard 2s cap) — frees the live-ASR
        // worker's memory before the offline/cloud pipeline needs it, and
        // never delays saving the recording's audio (plan §5.11).
        await stopLiveAssist()
        stopTicker()
        status = tr(L.statusFinishing)
        let dir = await rec.stop()
        recorder = nil
        refresh(); selectedID = dir.lastPathComponent
        hud?(HUDEvent(kind: .stopped, text: tr(L.saved)))
        await finishNewSession(dir, savedMessage: tr(L.saved))
    }

    /// Shared "what happens after a new session's audio exists on disk" path,
    /// used by both recording (`stopRecording`) and audio/video import
    /// (`AppState+Library.swift`'s `importMedia`): kicks off auto-transcription
    /// per the user's settings, or reports why it didn't. `internal` (not
    /// `private`): called cross-file from `importMedia`.
    func finishNewSession(_ dir: URL, savedMessage: String) async {
        let generation = processGeneration
        if usesOfflineTranscription {
            if autoTranscribe {
                if activeOfflineRuntime.state == .ready { process(dir) }
                else {
                    await activeOfflineCoordinator.markSetupRequired(sessionDir: dir, config: offlineConfig)
                    guard processGeneration == generation, !Task.isCancelled else { return }
                    state = .idle; status = "\(savedMessage). \(tr(L.installLocalEngineSuffix))"
                }
            } else { state = .idle; status = "\(savedMessage)." }
        } else if hasKeys && autoTranscribe { process(dir) }
        else {
            state = .idle
            status = hasKeys ? "\(savedMessage)." : "\(savedMessage). \(setupRequiredStatus)"
        }
    }

    // MARK: Live timer + meters
    private func startTicker() {
        ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            if self.state == .recording {
                self.meters.elapsed = Date().timeIntervalSince(start) - self.pausedAccum
                self.meters.micLevel = Self.norm(self.recorder?.micLevel() ?? -160)
                Task { if let r = self.recorder { let s = await r.systemLevel(); if self.state == .recording { self.meters.systemLevel = Self.norm(s) } } }
            }
        }
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil; meters.micLevel = 0; meters.systemLevel = 0 }
    static func norm(_ db: Float) -> Double { Double(max(0, min(1, (db + 60) / 60))) }
}
