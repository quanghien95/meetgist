// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button(state.isRecording ? "Stop recording" : "Start recording") {
            state.toggleRecording()
        }
        .keyboardShortcut("r")

        Divider()

        Text(state.status)

        if let m = state.meetings.first {
            Button("Open last: \(m.title)") {
                state.selectedID = m.id
                NSApp.activate(ignoringOtherApps: true)
                bringWindowForward()
            }
        }

        Button("Open MeetGist") {
            NSApp.activate(ignoringOtherApps: true)
            bringWindowForward()
        }

        Divider()
        Button("Quit MeetGist") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func bringWindowForward() {
        for w in NSApp.windows where w.canBecomeMain {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}
