// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import Combine

/// Opt-in tiny floating controller shown while recording when the user picks
/// "Mini floating controller" presence. Draggable; collapses to a 1-line pill.
@MainActor
final class MiniController {
    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()
    private weak var state: AppState?
    private let loc: Localization

    init(state: AppState, loc: Localization) {
        self.state = state
        self.loc = loc
        state.$state.combineLatest(state.$presence)
            .receive(on: RunLoop.main)
            .sink { [weak self] s, p in self?.update(s, p) }
            .store(in: &bag)
    }

    private func update(_ s: RecState, _ p: Presence) {
        let show = p == .mini && (s == .recording || s == .paused)
        show ? present() : dismiss()
    }

    private func present() {
        guard let state else { return }
        if panel == nil {
            let view = NSHostingView(rootView: MiniControllerView().environmentObject(state).environmentObject(loc))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 56),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            if let f = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.maxX - 210, y: f.maxY - 90))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    private func dismiss() { panel?.orderOut(nil) }
}

private struct MiniControllerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @CompatibleState private var collapsed = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(state.state == .paused ? Theme.amber : Theme.red)
                    .frame(width: 7, height: 7)
                LiveTimer(meters: state.meters, size: 12)
                Spacer(minLength: 4)
                Button { state.pauseResume() } label: {
                    Image(systemName: state.state == .paused ? "play.fill" : "pause.fill").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                Button { state.toggleRecording() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain)
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            if !collapsed {
                MiniLevel(meters: state.meters, track: .mic, label: loc.t(L.me))
                MiniLevel(meters: state.meters, track: .system, label: loc.t(L.system))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, collapsed ? 8 : 9)
        .frame(width: 190)
        .background(Theme.panel.opacity(0.97))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// The mini panel's compact labeled level bar; observes the meters directly.
private struct MiniLevel: View {
    @ObservedObject var meters: RecordingMeters
    let track: MeterTrack
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.mono(8, .semibold)).foregroundStyle(Theme.muted)
                .lineLimit(1).frame(width: 34, alignment: .leading)
            LevelBar(level: track == .mic ? meters.micLevel : meters.systemLevel,
                     tint: track == .mic ? Theme.mint : Theme.teal, segments: 20)
        }
    }
}
