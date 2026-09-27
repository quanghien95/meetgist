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
    /// Tint for native controls (segmented pickers, checkboxes, bordered
    /// buttons). They draw white labels on the tint, which is unreadable on
    /// the bright mint, so native controls get a deeper shade of it.
    static let controlTint = Color(hex: 0x1E9C6C)
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

// MARK: Settings cards

private struct CardDepthKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// How many `CardGroupBoxStyle` boxes enclose this view (0 = top level).
    var cardDepth: Int {
        get { self[CardDepthKey.self] }
        set { self[CardDepthKey.self] = newValue }
    }
}

/// Full-width flat card for grouped settings: a muted mono section label above
/// a panel with a 1px hairline. Nested boxes step up one surface (panel2) so
/// hierarchy reads without extra chrome.
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardGroupBox(configuration: configuration)
    }

    private struct CardGroupBox: View {
        let configuration: GroupBoxStyleConfiguration
        @Environment(\.cardDepth) private var depth

        var body: some View {
            VStack(alignment: .leading, spacing: depth == 0 ? 8 : 6) {
                configuration.label
                    .font(depth == 0 ? Theme.mono(10, .semibold) : Theme.ui(12, .medium))
                    .foregroundStyle(depth == 0 ? Theme.muted : Theme.text)
                    .textCase(depth == 0 ? .uppercase : nil)
                    .padding(.leading, depth == 0 ? 2 : 0)
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(depth == 0 ? 10 : 8)
                    .panel(depth == 0 ? Theme.panel : Theme.panel2)
                    .environment(\.cardDepth, depth + 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
