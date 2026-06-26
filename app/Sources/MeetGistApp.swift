// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI

@main
struct MeetGistApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra("MeetGist", systemImage: state.isRecording ? "record.circle.fill" : "waveform") {
            MenuBarView()
                .environmentObject(state)
        }
    }
}
