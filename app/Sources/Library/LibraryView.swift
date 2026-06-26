// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import MeetGistKit

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @State private var query = ""

    private var filtered: [Meeting] {
        guard !query.isEmpty else { return state.meetings }
        return state.meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var isLive: Bool { state.state == .recording || state.state == .paused }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).font(.system(size: 11))
                    TextField(loc.t(L.search), text: $query)
                        .textFieldStyle(.plain).font(Theme.mono(12))
                }
                .padding(8).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(10)

                List(selection: $state.selectedID) {
                    Section(loc.t(L.meetings)) {
                        ForEach(filtered) { m in MeetingRow(meeting: m).tag(m.id) }
                    }
                }
                .scrollContentBackground(.hidden)
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
        .onAppear { state.refresh() }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var loc: Localization
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(Theme.ui(13)).foregroundStyle(Theme.text).lineLimit(1)
            HStack(spacing: 8) {
                if let d = meeting.date {
                    Text(d, format: .dateTime.month().day().hour().minute())
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if meeting.hasNotes {
                    StatusPill(color: Theme.mint, text: loc.t(L.summary))
                } else {
                    StatusPill(color: Theme.muted, text: loc.t(L.saved))
                }
            }
        }
        .padding(.vertical, 3)
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
                    Text("记了吗").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.muted)
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
