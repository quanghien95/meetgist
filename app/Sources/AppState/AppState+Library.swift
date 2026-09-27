// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import AppKit
import UniformTypeIdentifiers
import MeetGistKit

// MARK: - Meetings
extension AppState {
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

    /// Scans both offline coordinators, excluding whichever session(s) are
    /// currently active on either one from BOTH scans — so, say, deleting an
    /// unrelated meeting (`moveMeetingToTrash`) can never race a scan against
    /// the folder either coordinator is actively transcribing into. See P0-5.
    /// `internal` (not `private`): called from `outputDir`'s `didSet` and
    /// `init` (`AppState.swift`), and from `moveMeetingToTrash` (this file).
    func scanOfflineCoordinators() {
        let active = Set([offlineCoordinator.activeSessionID, qwenASRCoordinator.activeSessionID].compactMap { $0 })
        offlineCoordinator.scan(outputDir: outputDir, excluding: active)
        qwenASRCoordinator.scan(outputDir: outputDir, excluding: active)
    }

    /// A meeting may have been transcribed by either local engine, independent
    /// of which one is currently selected — check both coordinators.
    func offlineJob(for meeting: Meeting) -> OfflineJobState? {
        offlineCoordinator.state(for: meeting.id) ?? qwenASRCoordinator.state(for: meeting.id)
    }

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
        importAudio(from: source)
    }

    /// Imports `source` as a new meeting (the file-picker-free half of
    /// `importAudio()`). The folder name is unique even for two imports in
    /// the same second, so an earlier import's audio is never overwritten.
    func importAudio(from source: URL) {
        guard recorder == nil else {
            status = tr(L.stopRecordingBeforeImport)
            return
        }
        guard state != .processing else {
            status = tr(L.waitCurrentTaskBeforeImport)
            return
        }
        let dir = outputDir
        state = .processing; status = tr(L.importingMessage)
        Task { [weak self] in
            guard let self else { return }
            do {
                let sessionDir = try SessionRecorder.makeSessionDir(
                    outputDir: dir, base: "imported-\(Self.importFolderStamp())")
                try await AudioTools.export(source, to: sessionDir.appendingPathComponent("mic.m4a"))
                // The folder name ends in a unix timestamp, which would otherwise
                // be shown as the title; the source file's name is more useful.
                try? MeetingStore.setTitle(source.deletingPathExtension().lastPathComponent,
                                           forSessionDir: sessionDir)
                self.refresh(); self.selectedID = sessionDir.lastPathComponent
                // The import itself is done; leave `.processing` before handing
                // off, or processOffline's "already processing" guard rejects
                // the auto-transcription and the app stays stuck in processing.
                self.state = .idle
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
}
