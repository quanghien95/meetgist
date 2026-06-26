// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import KeyboardShortcuts

@main
struct MeetGistApp: App {
    @StateObject private var state = AppState()
    @StateObject private var loc = Localization()
    private let hud = HUDController()

    var body: some Scene {
        Window("MeetGist", id: "main") {
            LibraryView()
                .environmentObject(state)
                .environmentObject(loc)
                .frame(minWidth: 880, minHeight: 560)
                .background(Theme.bg)
                .preferredColorScheme(.dark)
                .onAppear { setup() }
        }
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(state)
                .environmentObject(loc)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: menuIcon(state.state))
        }
        .menuBarExtraStyle(.window)
    }

    private func menuIcon(_ s: RecState) -> String {
        switch s {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        }
    }

    @MainActor private func setup() {
        state.hud = { [hud] event in hud.flash(event) }
        if !Self.hotkeyRegistered {
            Self.hotkeyRegistered = true
            KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak state] in state?.toggleRecording() }
        }
    }

    @MainActor private static var hotkeyRegistered = false
}
