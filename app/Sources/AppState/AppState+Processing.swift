// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import Combine
import MeetGistKit

// MARK: - Processing (cloud + offline transcription, notes generation, post-process)
extension AppState {
    /// Bumped whenever a new recording start or an explicit cancel makes the
    /// currently in-flight `processTask` stale — see `processGeneration`'s doc
    /// comment on `AppState.swift`. `internal` (not `private`): called from
    /// `AppState+Recording.swift`'s `startRecording`.
    @discardableResult
    func nextProcessGeneration() -> Int {
        processGeneration += 1
        return processGeneration
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
                let pipeline = try self.pipelineFactory(tp, self.key(for: tp),
                                                        np, self.key(for: np),
                                                        template, self.notesLanguage)
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
                // Progress follows the coordinator's published job state (it
                // reloads when the worker writes state.json); completion is a
                // signal from the coordinator, not a polling loop.
                let sessionID = dir.lastPathComponent
                let progress = coordinator.$jobs
                    .compactMap { $0[sessionID]?.progress.fraction }
                    .map { Int($0 * 100) }
                    .removeDuplicates()
                    .sink { [weak self] percent in
                        guard let self, self.processGeneration == generation, self.state == .processing else { return }
                        self.status = self.tr(L.localTranscriptionPercent(percent))
                    }
                await coordinator.waitUntilFinished(sessionID: sessionID)
                progress.cancel()
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
                self.refresh()
            }
        } else {
            state = .idle; status = tr(L.canceledMessage)
            // A canceled job may already have written transcript.md (e.g.
            // canceled during the notes stage); show it in the list.
            refresh()
        }
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
        let writer = try notesWriterFactory(provider, key(for: provider), template, notesLanguage)
        _ = try await MeetingProcessor.generateNotes(sessionDir: dir, writer: writer, providerName: provider.name) { [weak self] message in
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

    func reprocessSelected() { guard let m = selectedMeeting else { return }; process(m.dir) }
}
