// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import CoreGraphics

// Best-effort meeting-title detection. Requires Screen Recording permission
// (which we already need for SCK). Returns nil if nothing plausible is on
// screen — in that case we fall back to the timestamp-only folder name.
func detectMeetingTitle() -> String? {
    let meetingApps = [
        "zoom", "zoom.us",
        "google chrome", "chrome", "safari", "firefox", "microsoft edge", "arc", "brave",
        "wemeet", "tencent meeting", "腾讯会议",
        "microsoft teams", "teams",
        "webex", "cisco webex"
    ]

    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    for window in list {
        guard let owner = window[kCGWindowOwnerName as String] as? String,
              let name = window[kCGWindowName as String] as? String,
              !name.isEmpty else { continue }
        let ownerLower = owner.lowercased()
        guard meetingApps.contains(where: { ownerLower.contains($0) }) else { continue }

        let lname = name.lowercased()
        // For browsers, only grab titles that look meeting-ish
        if ownerLower.contains("chrome") || ownerLower.contains("safari")
            || ownerLower.contains("firefox") || ownerLower.contains("edge")
            || ownerLower.contains("arc") || ownerLower.contains("brave") {
            guard lname.contains("meet")
                    || lname.contains("zoom")
                    || lname.contains("webex")
                    || lname.contains("teams")
                    || lname.contains("tencent")
                    || lname.contains("腾讯") else { continue }
        }

        return sanitizeTitle(name)
    }
    return nil
}

private func sanitizeTitle(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        } else if scalar == " " || scalar == "-" || scalar == "_" {
            out.append("-")
        }
        // skip everything else, including CJK punctuation and emoji
    }
    // collapse repeated dashes
    while out.contains("--") {
        out = out.replacingOccurrences(of: "--", with: "-")
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if out.count > 40 { out = String(out.prefix(40)) }
    return out.isEmpty ? "meeting" : out
}
