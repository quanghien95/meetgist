// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    let meeting: Meeting
    @CompatibleState private var tab = Tab.summary
    @CompatibleState private var showRetranscribeConfirmation = false
    @CompatibleState private var isEditingTitle = false
    @CompatibleState private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool
    // Reading transcript.md/polished.md/summary.md and parsing the Markdown into
    // an AttributedString were both happening synchronously inside `body` (a
    // computed property + a plain function), so SwiftUI re-ran that file read
    // and full Markdown parse on every redraw, not just on selection — the
    // measured 1-2s open lag. Now loaded once per (meeting, tab) off the main
    // thread in `.task`, and cached here instead of recomputed per body pass.
    @CompatibleState private var renderedContent: [MarkdownBlock]?
    @CompatibleState private var rawContent: String?
    @CompatibleState private var contentStats: (words: Int, characters: Int)?
    // The transcript tab renders one row per `[MM:SS] Speaker: …` line in a
    // LazyVStack instead of one giant Text(AttributedString): a single Text
    // forces SwiftUI to lay out the entire transcript (often 1000+ lines) up
    // front even though only a screenful is visible, which is the remaining
    // per-tab-switch cost after the async load fix. Markdown parsing is also
    // skipped for this tab since transcript.md is plain timestamped lines,
    // not Markdown — parsing it was pure overhead.
    @CompatibleState private var transcriptLines: [String]?

    enum Tab: Hashable { case summary, minutes, transcript, postProcess }

    private var file: String {
        switch tab { case .summary: return "summary.md"; case .minutes: return "polished.md"; case .transcript: return "transcript.md"; case .postProcess: return PostProcessRunner.outputFile }
    }
    private var processingThis: Bool { state.state == .processing && state.selectedID == meeting.id }
    private var hasMic: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("mic.m4a").path) }
    private var hasSystem: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("system.m4a").path) }
    private var offlineJob: OfflineJobState? { state.offlineJob(for: meeting) }
    /// `offlineJob` only reflects `OfflineJobCoordinator`'s in-memory dictionary,
    /// which is populated by `scan()` at launch/import/delete — not by every
    /// path that can leave a meeting selected. A meeting genuinely transcribed
    /// offline always leaves a `transcription/` state directory on disk, so
    /// check that too rather than trusting only the in-memory job to still be
    /// there. Without this, "Regenerate Minutes" and "Re-transcribe" could both
    /// silently vanish for an already-transcribed meeting whenever the
    /// in-memory job state doesn't happen to cover it.
    private var isOfflineMeeting: Bool {
        offlineJob != nil
            || FileManager.default.fileExists(
                atPath: meeting.dir.appendingPathComponent("transcription").path)
    }
    private var reprocessDisabled: Bool {
        if state.usesOfflineTranscription {
            return [.recording, .paused, .processing].contains(state.state)
                || !state.canStartTranscription
        }
        if state.usesLocalNotes,
           [.recording, .paused].contains(state.state) { return true }
        return state.state == .processing || !state.hasKeys
    }
    private var hasTranscript: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("transcript.md").path) }
    private var hasGeneratedNotes: Bool {
        FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("polished.md").path)
            && FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("summary.md").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView {
                if tab == .transcript, let lines = transcriptLines {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            TranscriptLineView(line: line)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 22).padding(.vertical, 18)
                } else if let blocks = renderedContent {
                    MarkdownBlocksView(blocks: blocks)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.vertical, 18)
                } else {
                    placeholder.padding(40)
                }
            }
        }
        .background(Theme.bg)
        .task(id: TaskKey(meetingID: meeting.id, tab: tab, processing: state.state == .processing)) {
            await loadContent()
        }
        .confirmationDialog(
            loc.t(L.retranscribeConfirmation),
            isPresented: $showRetranscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button(loc.t(L.retranscribe), role: .destructive) {
                state.retranscribeOffline(meeting)
            }
            Button(loc.t(L.cancel), role: .cancel) { }
        } message: {
            Text(loc.t(L.retranscribeWarning))
        }
    }

    private struct TaskKey: Equatable {
        let meetingID: String
        let tab: Tab
        let processing: Bool
    }

    /// Reads the current tab's file and parses Markdown off the main thread,
    /// then hops back to publish the result. Re-runs when the meeting, the tab,
    /// or the processing flag (Generate/Regenerate finishing) changes — see
    /// `.task(id:)` above — so a completed Generate refreshes the same tab
    /// without needing a manual reload trigger.
    private func loadContent() async {
        // Clear the previous meeting/tab's cached content immediately so a
        // stale render never flashes while the new file loads off-main.
        rawContent = nil
        renderedContent = nil
        contentStats = nil
        transcriptLines = nil
        let dir = meeting.dir, currentFile = file, currentTab = tab
        let loaded = await Task.detached(priority: .userInitiated) { () -> (String?, [MarkdownBlock]?, [String]?, (Int, Int)?) in
            guard let text = MeetingStore.markdown(currentFile, in: dir),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return (nil, nil, nil, nil) }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let characters = text.count
            let stats = (words, characters)
            if currentTab == .transcript {
                // Plain timestamped lines, not Markdown — splitting is far
                // cheaper than a Markdown parse, and lets the LazyVStack lay
                // out only the rows that scroll into view.
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return (text, nil, lines, stats)
            }
            return (text, MarkdownBlock.parse(text), nil, stats)
        }.value
        guard !Task.isCancelled else { return }
        rawContent = loaded.0
        renderedContent = loaded.1
        transcriptLines = loaded.2
        contentStats = loaded.3.map { (words: $0.0, characters: $0.1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingTitle {
                        TextField("", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(Theme.ui(17, .semibold)).foregroundStyle(Theme.text)
                            .focused($titleFieldFocused)
                            .onSubmit { commitTitleEdit() }
                            .onExitCommand { isEditingTitle = false }
                            .onChange(of: titleFieldFocused) { _, focused in
                                // Clicking away from the field is a natural way
                                // to "finish" editing — commit rather than
                                // silently discarding what was typed.
                                if !focused && isEditingTitle { commitTitleEdit() }
                            }
                    } else {
                        Text(meeting.title).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .onTapGesture { beginTitleEdit() }
                            .help(loc.t(L.rename))
                    }
                    // Each item stays on one line; when the header is narrow the
                    // word/char stats are dropped first instead of wrapping
                    // the date and track labels mid-word.
                    ViewThatFits(in: .horizontal) {
                        metaRow(includeStats: true)
                        metaRow(includeStats: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Menu {
                        ForEach(Exporter.Format.allCases, id: \.self) { f in
                            Button(f.label) { exportAs(f) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Theme.text).fixedSize()
                    .frame(width: 26, height: 24)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Theme.panel2)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(loc.t(L.export))
                    iconButton("doc.on.doc", loc.t(L.copy)) { copy() }
                    iconButton("folder", loc.t(L.reveal)) { NSWorkspace.shared.open(meeting.dir) }
                    if isOfflineMeeting && hasTranscript {
                        Button(loc.t(hasGeneratedNotes ? L.regenerateMinutes : L.generateMinutes)) {
                            state.generateMinutes(meeting.dir)
                        }
                            .buttonStyle(GhostButton())
                            .disabled([.recording, .paused, .processing].contains(state.state)
                                      || !state.canGenerateMinutes)
                    } else {
                        iconButton("arrow.clockwise", loc.t(L.regenerate)) { state.reprocessSelected() }
                            .disabled(reprocessDisabled)
                    }
                    iconButton("terminal", loc.t(L.runPostProcessScript)) { state.runPostProcess(meeting) }
                        .disabled(state.state == .processing || state.postProcessSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .fixedSize()
            }
            HStack(spacing: 6) {
                segTab(loc.t(L.summary), .summary)
                segTab(loc.t(L.minutes), .minutes)
                segTab(loc.t(L.transcript), .transcript)
                if state.postProcessEnabled || FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent(PostProcessRunner.outputFile).path) {
                    segTab(loc.t(L.postProcessTab), .postProcess)
                }
                Spacer()
                // Once transcription is done, the progress card (100% bar,
                // per-track "Completed" rows, ETA) has nothing left to say —
                // only the retry action is still relevant, so it sits on the
                // tab row instead of taking a row of its own. This also covers
                // the case where the in-memory job state is gone (e.g. after
                // an app relaunch) but transcript.md still exists on disk —
                // `offlineJob` alone would hide this button entirely then.
                if isOfflineMeeting && hasTranscript && (offlineJob == nil || offlineJob?.status == .completed) {
                    Button { showRetranscribeConfirmation = true } label: {
                        Label(loc.t(L.retranscribe), systemImage: "arrow.counterclockwise")
                            .font(Theme.ui(12))
                    }
                    .buttonStyle(GhostButton(compact: true))
                    .disabled(state.state == .processing)
                }
            }
            if let job = offlineJob, job.status != .completed {
                offlineProgress(job)
            }
        }
        .padding(16)
    }

    private func metaRow(includeStats: Bool) -> some View {
        HStack(spacing: 10) {
            if let d = meeting.date {
                Text(d, format: .dateTime.weekday().month().day().hour().minute())
            }
            if let duration = meeting.formattedDuration {
                Text("· \(duration)")
            }
            if includeStats, let stats = contentStats {
                Text(loc.t(L.statsWordsChars(words: stats.words, characters: stats.characters)))
            }
            // Audio tracks status
            HStack(spacing: 4) {
                Circle().fill(hasMic ? Theme.mint : Theme.line).frame(width: 6, height: 6)
                Text(loc.t(L.me)).font(Theme.mono(9))
                Circle().fill(hasSystem ? Theme.teal : Theme.line).frame(width: 6, height: 6)
                    .padding(.leading, 4)
                Text(loc.t(L.system)).font(Theme.mono(9))
            }
        }
        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        .lineLimit(1).fixedSize()
    }

    private func segTab(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title).font(Theme.mono(11, .medium))
                .foregroundStyle(tab == value ? Theme.bg : Theme.muted)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(tab == value ? Theme.mint : Theme.panel2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if processingThis {
                HStack(spacing: 10) {
                    stepDot(loc.t(L.transcribing), active: state.processStep == 0, done: state.processStep > 0)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.line)
                    stepDot(loc.t(L.summarizing), active: state.processStep == 1, done: false)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.line)
                    stepDot(loc.t(L.done), active: false, done: false)
                }
                Text(state.status).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Button(loc.t(L.cancel)) { state.cancelProcessing() }.buttonStyle(GhostButton())
            } else if isOfflineMeeting && hasTranscript && tab != .transcript {
                Image(systemName: "doc.text.magnifyingglass").font(.title).foregroundStyle(Theme.muted)
                Text(loc.t(state.canGenerateMinutes ? L.notesSeparateStage : L.notesNeedProvider))
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                Button(loc.t(L.generateMinutes)) { state.generateMinutes(meeting.dir) }
                    .buttonStyle(MintButton())
                    .disabled([.recording, .paused, .processing].contains(state.state)
                              || !state.canGenerateMinutes)
            } else if state.usesOfflineTranscription {
                Image(systemName: "waveform.badge.magnifyingglass").font(.title).foregroundStyle(Theme.muted)
                // `offlineJob?.lastError` is produced by MeetGistKit and stays
                // English; only the "not ready yet" fallback is localized.
                Text(offlineJob?.lastError ?? loc.t(L.localTranscriptNotReady))
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if let job = offlineJob, [.pending, .paused, .canceled].contains(job.status) {
                    Button(loc.t(L.resume)) { state.resumeOffline(meeting) }.buttonStyle(MintButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                } else if offlineJob?.status == .failed {
                    Button(loc.t(L.retry)) { state.retryOffline(meeting) }.buttonStyle(MintButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                } else {
                    // No job at all yet — this meeting has never been
                    // transcribed (imported audio, or offline transcription
                    // wasn't selected at recording time). `resumeOffline`
                    // starts a fresh job from scratch just as well as it
                    // resumes an interrupted one — `coordinator.start(...)`
                    // doesn't require prior state to exist.
                    Button(loc.t(L.transcribe)) { state.resumeOffline(meeting) }.buttonStyle(MintButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                }
            } else if !state.hasKeys {
                Image(systemName: "key").font(.title).foregroundStyle(Theme.amber)
                Text(loc.t(L.needKey)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "doc.text").font(.title).foregroundStyle(Theme.muted)
                Text("—").foregroundStyle(Theme.muted)
                Button(loc.t(L.regenerate)) { state.reprocessSelected() }.buttonStyle(MintButton())
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private func offlineProgress(_ job: OfflineJobState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(loc.t(L.localTranscription)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(Int(job.progress.fraction * 100))%")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            ProgressView(value: job.progress.fraction).tint(Theme.mint)
            if let currentTrack = job.progress.currentTrack,
               let currentChunk = job.progress.currentChunk {
                let track = currentTrack == "system" ? loc.t(L.system) : loc.t(L.microphone)
                Text("\(track) · \(loc.t(L.chunk)) \(currentChunk + 1)")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            trackProgress(loc.t(L.system), key: "system", job: job)
            trackProgress(loc.t(L.microphone), key: "mic", job: job)
            HStack {
                if let eta = job.progress.etaSeconds, job.status == .transcribing {
                    Text("\(loc.t(L.etaLabel))  \(formatETA(eta))").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                switch job.status {
                case .transcribing:
                    Button(loc.t(L.pause)) { state.pauseOffline() }.buttonStyle(GhostButton())
                    Button(loc.t(L.cancel)) { state.cancelProcessing() }.buttonStyle(GhostButton())
                case .pending, .paused, .canceled:
                    Button(loc.t(L.resume)) { state.resumeOffline(meeting) }.buttonStyle(GhostButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                case .failed:
                    Button(loc.t(L.retry)) { state.retryOffline(meeting) }.buttonStyle(GhostButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                case .completed:
                    Button(loc.t(L.retranscribe)) { showRetranscribeConfirmation = true }
                        .buttonStyle(GhostButton())
                        .disabled(state.state == .processing)
                }
            }
            if let error = job.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(Theme.amber)
            }
            ForEach(job.warnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(Theme.amber)
            }
        }
        .padding(10)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func trackProgress(_ label: String, key: String, job: OfflineJobState) -> some View {
        HStack {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.muted)
            Spacer()
            if let track = job.tracks[key] {
                let processed = job.progress.trackProcessedSeconds[key] ?? 0
                Text(processed >= track.durationSeconds - 0.01 ? loc.t(L.completedLabel) : "\(Int(min(1, processed / max(0.001, track.durationSeconds)) * 100))%")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            } else {
                Text(loc.t(L.skippedLabel)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return loc.t(L.etaLessThanMinute) }
        return loc.t(L.etaMinutes(Int(ceil(Double(seconds) / 60))))
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 24) }
            .buttonStyle(GhostButton(compact: true)).help(help)
    }

    private func copy() {
        guard let c = rawContent else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
    }

    private func beginTitleEdit() {
        titleDraft = meeting.title
        isEditingTitle = true
        titleFieldFocused = true
    }

    private func commitTitleEdit() {
        isEditingTitle = false
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        state.renameMeeting(meeting, to: trimmed)
    }

    private func exportAs(_ f: Exporter.Format) {
        if let url = try? Exporter.write(f, sessionDir: meeting.dir) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func stepDot(_ title: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(done ? Theme.mint : (active ? Theme.teal : Theme.panel2)).frame(width: 14, height: 14)
                if done { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.bg) }
                else if active { Circle().fill(Theme.bg).frame(width: 5, height: 5) }
            }
            Text(title).font(Theme.mono(10)).foregroundStyle(active || done ? Theme.text : Theme.muted)
        }
    }

}
