// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit

struct MenuBarPopover: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @Environment(\.openWindow) private var openWindow

    private var isLive: Bool { state.state == .recording || state.state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                StatusPill(color: statusColor(state.state),
                           text: statusText(state.state, loc),
                           pulse: state.state == .recording)
                Spacer()
                if isLive { TimerLabel(seconds: state.elapsed, size: 13) }
            }

            if isLive {
                LabeledLevel(label: loc.t(L.me), level: state.micLevel, tint: Theme.mint)
                LabeledLevel(label: loc.t(L.system), level: state.systemLevel, tint: Theme.teal)
            } else {
                Text("▸ \(loc.t(L.tagline))").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }

            HStack(spacing: 8) {
                Button(isLive ? loc.t(L.stop) : loc.t(L.start)) { state.toggleRecording() }
                    .buttonStyle(MintButton())
                if isLive {
                    Button(state.state == .paused ? loc.t(L.resume) : loc.t(L.pause)) { state.pauseResume() }
                        .buttonStyle(GhostButton())
                }
                Spacer()
            }

            Divider().overlay(Theme.line)

            VStack(spacing: 1) {
                row(loc.t(L.openApp), "macwindow") { openMain() }
                row(loc.t(L.transcribeLatest), "text.viewfinder") {
                    if let m = state.meetings.first { Task { await state.process(m.dir) } }
                }
                row(loc.t(L.settings), "gearshape") { state.showSettings = true; openMain() }
                row(loc.t(L.quit), "power") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 282)
        .background(Theme.bg)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(Theme.muted)
                Text(title).font(Theme.ui(13)).foregroundStyle(Theme.text)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5).padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
