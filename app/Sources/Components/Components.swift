// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI

// MARK: Status

func statusColor(_ s: RecState) -> Color {
    switch s {
    case .idle: return Theme.muted
    case .recording: return Theme.red
    case .paused: return Theme.amber
    case .processing: return Theme.teal
    case .error: return Theme.red
    }
}

@MainActor func statusText(_ s: RecState, _ loc: Localization) -> String {
    switch s {
    case .idle: return loc.t(L.idle)
    case .recording: return loc.t(L.recording)
    case .paused: return loc.t(L.paused)
    case .processing: return loc.t(L.processing)
    case .error: return loc.t(L.error)
    }
}

/// A small status pill: ● colored dot + label, mono.
struct StatusPill: View {
    let color: Color
    let text: String
    var pulse = false
    @CompatibleState private var on = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(pulse ? (on ? 1 : 0.35) : 1)
                .animation(pulse ? .easeInOut(duration: 0.8).repeatForever() : .default, value: on)
            Text(text).font(Theme.mono(11, .medium)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.panel2).clipShape(Capsule())
        .onAppear { on = true }
    }
}

// MARK: Level bar (segmented mono blocks)

struct LevelBar: View {
    let level: Double          // 0…1
    var tint: Color = Theme.mint
    var segments = 14
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let on = Double(i) / Double(segments) < level
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? tint.opacity(0.95) : Theme.line)
                    .frame(width: 4, height: 10)
            }
        }
    }
}

struct LabeledLevel: View {
    let label: String
    let level: Double
    var tint: Color = Theme.mint
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 46, alignment: .leading)
            LevelBar(level: level, tint: tint)
        }
    }
}

// MARK: Timer

struct TimerLabel: View {
    let seconds: TimeInterval
    var size: CGFloat = 13
    var body: some View {
        Text(Self.fmt(seconds)).font(Theme.mono(size, .medium)).foregroundStyle(Theme.text)
            .monospacedDigit()
    }
    static func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: Buttons

struct MintButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MintButtonBody(configuration: configuration)
    }
}

private struct MintButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        configuration.label
            .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.bg)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.mint.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct GhostButton: ButtonStyle {
    /// Tighter padding for icon-only buttons in dense toolbars.
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, compact: compact)
    }
}

private struct GhostButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        configuration.label
            .font(Theme.ui(13)).foregroundStyle(Theme.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, compact ? 6 : 14).padding(.vertical, compact ? 4 : 7)
            .background(Theme.panel2.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: Live recording readouts
// Each observes `RecordingMeters` directly, so the 10 Hz ticker re-renders only
// these small views instead of everything observing `AppState`.

struct LiveTimer: View {
    @ObservedObject var meters: RecordingMeters
    var size: CGFloat = 13
    var body: some View { TimerLabel(seconds: meters.elapsed, size: size) }
}

enum MeterTrack { case mic, system }

struct LiveLevel: View {
    @ObservedObject var meters: RecordingMeters
    let track: MeterTrack
    let label: String
    var body: some View {
        LabeledLevel(label: label,
                     level: track == .mic ? meters.micLevel : meters.systemLevel,
                     tint: track == .mic ? Theme.mint : Theme.teal)
    }
}
