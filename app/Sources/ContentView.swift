// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import MeetGistKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selectedID) {
                Section("Meetings") {
                    ForEach(state.meetings) { m in
                        MeetingRow(meeting: m).tag(m.id)
                    }
                    if state.meetings.isEmpty {
                        Text("No meetings yet.\nPress Record to start.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .navigationTitle("MeetGist")
        } detail: {
            if let m = state.selectedMeeting {
                MeetingDetailView(meeting: m)
            } else {
                EmptyDetail()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.toggleRecording()
                } label: {
                    Label(state.isRecording ? "Stop" : "Record",
                          systemImage: state.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(state.isRecording ? .red : .accentColor)
                .help(state.isRecording ? "Stop recording" : "Start recording")
            }
            ToolbarItem(placement: .automatic) {
                if state.processing { ProgressView().controlSize(.small) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle().fill(state.isRecording ? .red : .secondary).frame(width: 8, height: 8)
                Text(state.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !state.hasKeys {
                    Button("Add API key") { showSettings = true }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(state)
        }
        .onAppear { state.refresh() }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                if let d = meeting.date {
                    Text(d, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meeting.hasNotes {
                    Image(systemName: "doc.text").font(.caption2).foregroundStyle(.green)
                }
            }
        }.padding(.vertical, 2)
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("MeetGist").font(.title2.bold())
            Text("Bot-free Mac meeting notes. Press **Record**, hold your meeting, then stop — MeetGist captures your mic and the system audio separately and writes the notes here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if !state.hasKeys {
                Text("Add a free-tier API key in Settings to generate transcripts.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }.padding()
    }
}
