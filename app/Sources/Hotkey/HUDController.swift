// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit

/// A tiny, borderless, non-activating panel near the top-right that flashes a
/// 1–2s status (● REC / ■ Saved / ↻ …). Never steals focus or covers the meeting.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func flash(_ event: HUDEvent) {
        let view = NSHostingView(rootView: HUDView(event: event))
        let size = NSSize(width: 168, height: 40)
        view.frame = NSRect(origin: .zero, size: size)

        let panel = self.panel ?? makePanel(size)
        panel.contentView = view
        position(panel, size: size)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideTask?.cancel()
        hideTask = Task { [weak panel] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; panel.animator().alphaValue = 0 } completionHandler: { panel.orderOut(nil) }
        }
    }

    private func makePanel(_ size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.maxX - size.width - 16
        let y = f.maxY - size.height - 12
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private struct HUDView: View {
    let event: HUDEvent
    var color: Color {
        switch event.kind {
        case .recording, .error: return Theme.red
        case .stopped, .done: return Theme.mint
        case .processing: return Theme.teal
        }
    }
    var glyph: String {
        switch event.kind {
        case .recording: return "●"; case .stopped: return "■"
        case .processing: return "↻"; case .done: return "✓"; case .error: return "!"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(glyph).font(Theme.mono(13, .bold)).foregroundStyle(color)
            Text(event.text).font(Theme.mono(13, .medium)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.96))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
