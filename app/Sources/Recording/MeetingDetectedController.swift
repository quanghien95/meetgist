// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AppKit

@MainActor
final class MeetingDetectedController {
    private var panel: NSPanel?
    func present(state: AppState, title: String) {
        let view = NSHostingView(rootView: MeetingDetectedView(title: title) {
            self.panel?.orderOut(nil); state.toggleRecording()
        } onDismiss: { self.panel?.orderOut(nil) }
        )
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 285, height: 108),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating; panel.backgroundColor = .clear
        panel.isOpaque = false; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        if let frame = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.maxX - 305, y: frame.maxY - 142)) }
        self.panel = panel; panel.orderFrontRegardless()
    }
}

private struct MeetingDetectedView: View {
    let title: String; let onRecord: () -> Void; let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "video.fill").foregroundStyle(Theme.mint)
                Text("Meeting detected").font(Theme.ui(14, .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            Text(title).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            Button("Record now", action: onRecord).buttonStyle(MintButton())
        }.padding(14).frame(width: 285).background(Theme.panel.opacity(0.98)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
