// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import MeetGistKit

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @State private var query = ""
    @State private var meetingToRename: Meeting?
    @State private var renameText = ""
    @State private var meetingToDelete: Meeting?
    @State private var showRename = false
    @State private var showDelete = false

    private var filtered: [Meeting] {
        guard !query.isEmpty else { return state.meetings }
        return state.meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var isLive: Bool { state.state == .recording || state.state == .paused }
    /// A bare "42" in the status bar read as unlabeled noise — spell out what
    /// it counts. English distinguishes "1 meeting" from "N meetings"; zh has
    /// no singular/plural distinction so the localized noun covers both.
    private var meetingsCountLabel: String {
        let count = state.meetings.count
        if loc.effective == .zh { return "\(count) \(loc.t(L.meetingsCount))" }
        return count == 1 ? loc.t(L.oneMeeting) : "\(count) \(loc.t(L.meetingsCount))"
    }

    /// Only the meeting actively being processed is locked; finished meetings
    /// stay renameable/deletable even while another one is transcribing or a
    /// different meeting is being recorded.
    private func isProcessing(_ meeting: Meeting) -> Bool {
        guard state.state == .processing else { return false }
        if let active = state.activeOfflineCoordinator.activeSessionID { return meeting.id == active }
        return meeting.id == state.selectedID
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).font(.system(size: 11))
                        TextField(loc.t(L.search), text: $query)
                            .textFieldStyle(.plain).font(Theme.mono(12))
                    }
                    .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 7))

                    Button { state.importAudio() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 7))
                    .help(loc.t(L.importAudio))
                }
                .padding(10)

                List(selection: $state.selectedID) {
                    Section(loc.t(L.meetings)) {
                        ForEach(filtered) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                canManage: !isProcessing(meeting),
                                onRename: {
                                    meetingToRename = meeting
                                    renameText = meeting.title
                                    showRename = true
                                },
                                onDelete: { requestDelete(meeting) }
                            )
                            .tag(meeting.id)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onDeleteCommand { requestDeleteSelectedMeeting() }
            }
            .background(Theme.bg)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            Group {
                if let m = state.selectedMeeting { MeetingDetailView(meeting: m) }
                else { EmptyLibrary() }
            }
            .background(Theme.bg)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.toggleRecording() } label: {
                    Label(isLive ? loc.t(L.stop) : loc.t(L.record),
                          systemImage: isLive ? "stop.circle.fill" : "record.circle")
                }
                .tint(isLive ? Theme.red : Theme.mint)
            }
            ToolbarItem(placement: .automatic) {
                if state.state == .processing { ProgressView().controlSize(.small) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { state.showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                StatusPill(color: statusColor(state.state), text: statusText(state.state, loc),
                           pulse: state.state == .recording)
                if isLive { TimerLabel(seconds: state.elapsed, size: 11) }
                Text(state.status).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                if state.isLoadingMeetings {
                    ProgressView().controlSize(.small)
                    Text("\(loc.t(L.loadingMeetings)) (\(state.meetings.count))")
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                } else {
                    Text(meetingsCountLabel)
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                if !state.hasKeys {
                    Button(loc.t(L.settings)) { state.showSettings = true }.buttonStyle(.link).font(.callout)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.panel)
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsView().environmentObject(state).environmentObject(loc).preferredColorScheme(.dark)
        }
        .alert(loc.t(L.renameMeeting), isPresented: $showRename) {
            TextField(loc.t(L.meetingName), text: $renameText)
            Button(loc.t(L.rename)) {
                if let meetingToRename { state.renameMeeting(meetingToRename, to: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(loc.t(L.cancel), role: .cancel) { }
        }
        .confirmationDialog(
            loc.t(L.deleteMeeting), isPresented: $showDelete, titleVisibility: .visible
        ) {
            Button(loc.t(L.moveToTrash), role: .destructive) {
                if let meetingToDelete { state.moveMeetingToTrash(meetingToDelete) }
            }
            Button(loc.t(L.cancel), role: .cancel) { }
        } message: {
            Text(loc.t(L.deleteMeetingWarning))
        }
        .onAppear { state.refresh() }
    }

    private func requestDelete(_ meeting: Meeting) {
        meetingToDelete = meeting
        showDelete = true
    }

    private func requestDeleteSelectedMeeting() {
        guard !isLive,
              let selectedID = state.selectedID,
              let meeting = state.meetings.first(where: { $0.id == selectedID }),
              !isProcessing(meeting)
        else { return }
        requestDelete(meeting)
    }
}

struct MeetingRow: View {
    @EnvironmentObject var loc: Localization
    let meeting: Meeting
    let canManage: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    private var status: (color: Color, label: String) {
        if meeting.hasNotes { return (Theme.mint, loc.t(L.summary)) }
        if meeting.hasTranscript { return (Theme.teal, loc.t(L.transcript)) }
        return (Theme.muted, loc.t(L.saved))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(Theme.ui(13)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                // The sidebar is narrow: a full "● Transcript" pill here pushed the
                // date into "24 Sep a…". A status dot (label in the tooltip and in
                // the detail view) keeps the date and duration fully readable.
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                        .help(status.label)
                    if let d = meeting.date {
                        Text(d, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let duration = meeting.formattedDuration {
                        Text("· \(duration)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button(loc.t(L.rename), action: onRename)
                Button(loc.t(L.moveToTrash), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.muted)
            .fixedSize()
            .disabled(!canManage)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    var body: some View {
        VStack(spacing: 20) {
            Image("Logo").resizable().interpolation(.high)
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Theme.mint.opacity(0.18), radius: 26, y: 8)

            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("MeetGist").font(.system(size: 38, weight: .bold)).foregroundStyle(Theme.text)
                        .tracking(-0.5)
                    // Show the Chinese wordmark only in Chinese, so English stays all-English.
                    if loc.effective == .zh {
                        Text("记了吗").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                }
                Text(loc.t(L.tagline)).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.mint)
            }

            HStack(spacing: 10) {
                outputPill("doc.text", loc.t(L.transcript))
                outputPill("list.bullet.rectangle.portrait", loc.t(L.minutes))
                outputPill("sparkles", loc.t(L.summary))
            }

            Text(loc.t(L.emptyHint)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 420).lineSpacing(2)

            if !state.hasKeys {
                Button {
                    state.showSettings = true
                } label: { Label(loc.t(L.needKey), systemImage: "key.fill") }
                    .buttonStyle(GhostButton())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func outputPill(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.teal)
            Text(text).font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Theme.panel2).clipShape(Capsule())
    }
}
