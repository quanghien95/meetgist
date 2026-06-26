// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import AVFoundation
import CoreGraphics

/// Microphone + Screen Recording permission helpers. We request explicitly (rather than
/// letting the capture APIs prompt implicitly) so the OS shows MeetGist's usage strings
/// up front, and so a denial surfaces as a clear dialog instead of a silent empty track.
enum Permissions {
    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Returns true if authorized; prompts once if the status is undetermined.
    @discardableResult
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false   // denied / restricted — user must change it in System Settings
        }
    }

    static func screenRecordingAuthorized() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording if not yet granted. Returns the current status.
    /// (Granting it takes effect only after the app is relaunched — macOS behavior.)
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess() ? true : CGRequestScreenCaptureAccess()
    }
}
