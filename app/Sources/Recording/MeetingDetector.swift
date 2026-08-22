// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine

/// Best-effort foreground-meeting detection. Browser detection relies on the
/// visible window title, so it never reads browser history or page contents.
@MainActor
final class MeetingDetector {
    private weak var state: AppState?
    private let center = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []
    private var timer: AnyCancellable?
    private var lastFingerprint: String?

    init(state: AppState) {
        self.state = state
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        })
        timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.check() }
        check()
    }

    deinit { observers.forEach { center.removeObserver($0) }; timer?.cancel() }

    private func check() {
        guard let state, state.detectMeetings, state.state == .idle else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let fingerprint = matchingMeeting(app) else {
            // A subsequent Google Meet/Teams call must be able to prompt again.
            // Keep the fingerprint only while its matching window is foreground.
            lastFingerprint = nil
            return
        }
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        state.presentMeetingDetected(title: fingerprint)
    }

    private func matchingMeeting(_ app: NSRunningApplication) -> String? {
        let bundle = app.bundleIdentifier ?? ""
        let title = frontWindowTitle(for: app).lowercased()
        if bundle.hasPrefix("com.microsoft.teams") {
            return title.contains("meeting") || title.contains("call") ? "Microsoft Teams meeting" : nil
        }
        let name = app.localizedName?.lowercased() ?? ""
        if name.contains("google meet") { return "Google Meet" }
        guard bundle == "com.google.Chrome" || bundle == "com.microsoft.edgemac" || bundle == "org.mozilla.firefox" else { return nil }
        return title.contains("google meet") || title.contains(" meet ") ? "Google Meet" : nil
    }

    private func frontWindowTitle(for app: NSRunningApplication) -> String {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            ?? []
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
        }?[kCGWindowName as String] as? String ?? ""
    }
}
