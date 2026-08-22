// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    let meeting: Meeting
    @State private var tab = Tab.summary
    @State private var showRetranscribeConfirmation = false

    enum Tab: Hashable { case summary, minutes, transcript }

    private var file: String {
        switch tab { case .summary: return "summary.md"; case .minutes: return "polished.md"; case .transcript: return "transcript.md" }
    }
    private var content: String? { MeetingStore.markdown(file, in: meeting.dir) }
    private var processingThis: Bool { state.state == .processing && state.selectedID == meeting.id }
    private var hasMic: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("mic.m4a").path) }
    private var hasSystem: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("system.m4a").path) }
    private var offlineJob: OfflineJobState? { state.offlineJob(for: meeting) }
    private var isOfflineMeeting: Bool { offlineJob != nil }
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
                if let c = content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(md(c)).textSelection(.enabled).font(Theme.ui(13))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    placeholder.padding(40)
                }
            }
        }
        .background(Theme.bg)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        if let d = meeting.date {
                            Text(d, format: .dateTime.weekday().month().day().hour().minute())
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        }
                        // Audio tracks status
                        HStack(spacing: 4) {
                            Circle().fill(hasMic ? Theme.mint : Theme.line).frame(width: 6, height: 6)
                            Text(loc.t(L.me)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                            Circle().fill(hasSystem ? Theme.teal : Theme.line).frame(width: 6, height: 6)
                            Text(loc.t(L.system)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Menu {
                        ForEach(Exporter.Format.allCases, id: \.self) { f in
                            Button(f.label) { exportAs(f) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize().help(loc.t(L.export))
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
                }
            }
            HStack(spacing: 6) {
                segTab(loc.t(L.summary), .summary)
                segTab(loc.t(L.minutes), .minutes)
                segTab(loc.t(L.transcript), .transcript)
                Spacer()
            }
            if let job = offlineJob { offlineProgress(job) }
        }
        .padding(16)
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
                Text(offlineJob?.lastError ?? "Local transcript is not ready.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if let job = offlineJob, [.pending, .paused, .canceled].contains(job.status) {
                    Button(loc.t(L.resume)) { state.resumeOffline(meeting) }.buttonStyle(MintButton())
                        .disabled([.recording, .paused, .processing].contains(state.state)
                                  || !state.canStartTranscription)
                } else if offlineJob?.status == .failed {
                    Button(loc.t(L.retry)) { state.retryOffline(meeting) }.buttonStyle(MintButton())
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
                    Text("ETA  \(formatETA(eta))").font(Theme.mono(10)).foregroundStyle(Theme.muted)
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
                Text(processed >= track.durationSeconds - 0.01 ? "Completed" : "\(Int(min(1, processed / max(0.001, track.durationSeconds)) * 100))%")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            } else {
                Text("Skipped").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "< 1 min" }
        return "\(Int(ceil(Double(seconds) / 60))) min"
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 24) }
            .buttonStyle(GhostButton()).help(help)
    }

    private func copy() {
        guard let c = content else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
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

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
