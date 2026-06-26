// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI

/// MeetGist visual language: dark-first graphite + terminal-mint, flat, low-chrome,
/// SF Mono for timers/levels/status. No gradients/blobs/SaaS chrome.
enum Theme {
    static let bg      = Color(hex: 0x0B0C0E)
    static let panel   = Color(hex: 0x15171A)
    static let panel2  = Color(hex: 0x1C1F24)
    static let line    = Color(hex: 0x262A30)
    static let text    = Color(hex: 0xE6E8EB)
    static let muted   = Color(hex: 0x8A9099)
    static let mint    = Color(hex: 0x5CF2B0)   // primary accent
    static let teal    = Color(hex: 0x38E0D0)
    static let amber   = Color(hex: 0xF2B85C)   // warning
    static let red     = Color(hex: 0xFF5C5C)   // error / recording

    // Set by `Localization` to match the effective UI language. SF Mono carries no
    // CJK glyphs, so in Chinese a monospaced run forces a clashing PingFang fallback
    // mid-string ("mixed fonts"). When CJK, drop the monospaced *design* but keep
    // monospaced digits, so Latin + 中文 render in one consistent family.
    static var cjk = false

    // Type
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        cjk
            ? .system(size: size, weight: weight).monospacedDigit()
            : .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Metrics
    static let radius: CGFloat = 10
    static let gap: CGFloat = 12
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// A flat panel surface with a 1px hairline border.
struct PanelBackground: ViewModifier {
    var fill: Color = Theme.panel
    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

extension View {
    func panel(_ fill: Color = Theme.panel) -> some View { modifier(PanelBackground(fill: fill)) }
}
