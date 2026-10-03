// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Drops turns that would add noise rather than signal, before they ever
/// reach `LiveMeetingState`'s context or the semantic LLM (plan §5.8). Pure
/// and synchronous — the caller (`LiveCopilotEngine`) supplies the small
/// amount of recent-turn context each rule needs.
public struct LiveTurnFilter: Sendable {
    public struct Config: Sendable {
        public var minWordCount: Int
        public var minDurationSeconds: Double
        /// How many of the most recent turns *on the same track* count as
        /// "recent" for the same-track duplicate rule.
        public var recentSameTrackWindow: Int
        public var duplicateJaccardThreshold: Double
        /// A mic turn overlapping a system turn within this many seconds,
        /// judged a duplicate at a looser threshold, is speaker audio
        /// leaking into the mic (no headphones) rather than the user
        /// actually repeating it.
        public var micEchoWindowSeconds: Double
        public var micEchoJaccardThreshold: Double

        public init(minWordCount: Int = 2, minDurationSeconds: Double = 0.8,
                    recentSameTrackWindow: Int = 3, duplicateJaccardThreshold: Double = 0.9,
                    micEchoWindowSeconds: Double = 3.0, micEchoJaccardThreshold: Double = 0.6) {
            self.minWordCount = minWordCount
            self.minDurationSeconds = minDurationSeconds
            self.recentSameTrackWindow = recentSameTrackWindow
            self.duplicateJaccardThreshold = duplicateJaccardThreshold
            self.micEchoWindowSeconds = micEchoWindowSeconds
            self.micEchoJaccardThreshold = micEchoJaccardThreshold
        }
    }

    /// vi/en filler words the plan calls out by name (§5.8), stored already
    /// run through `LiveTextNormalize.normalize` (diacritics folded) since
    /// that's the form `isFiller` compares against — "ừ"/"vâng"/"dạ" would
    /// never match their own literal (accented) spelling otherwise. Checked
    /// against the *whole* normalized turn or word-by-word (both fully
    /// filler), so "ok vậy đi" (a real sentence containing "ok") is not
    /// treated as filler.
    static let fillerPhrases: Set<String> = Set(
        ["ừ", "ừm", "vâng", "dạ", "ok", "okay", "yeah", "uh huh", "mm", "right", "yes"]
            .map(LiveTextNormalize.normalize)
    )

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// True if `turn` should be dropped entirely — not kept as context, not
    /// sent for semantic analysis.
    public func shouldDrop(_ turn: LiveTranscriptTurn,
                           recentSameTrack: [LiveTranscriptTurn],
                           recentOtherTrack: [LiveTranscriptTurn]) -> Bool {
        let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let wordCount = trimmed.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let duration = turn.endedAt - turn.startedAt
        if wordCount < config.minWordCount && duration < config.minDurationSeconds { return true }

        if Self.isFiller(trimmed) { return true }

        let sameTrackRecent = recentSameTrack.suffix(config.recentSameTrackWindow)
        if sameTrackRecent.contains(where: {
            LiveTextNormalize.isDuplicate($0.text, trimmed, jaccardThreshold: config.duplicateJaccardThreshold)
        }) { return true }

        if turn.track == .me {
            if recentOtherTrack.contains(where: { isMicEcho(turn, of: $0) }) { return true }
        }

        return false
    }

    /// Shared in both arrival orders: system audio is authoritative when a
    /// temporally overlapping mic turn contains the same speech.
    public func isMicEcho(_ mic: LiveTranscriptTurn, of speaker: LiveTranscriptTurn) -> Bool {
        guard mic.track == .me, speaker.track == .speaker else { return false }
        let overlaps = abs(speaker.startedAt - mic.startedAt) <= config.micEchoWindowSeconds
            || (speaker.startedAt < mic.endedAt && speaker.endedAt > mic.startedAt)
        return overlaps && LiveTextNormalize.isDuplicate(mic.text, speaker.text,
                                                         jaccardThreshold: config.micEchoJaccardThreshold)
    }

    static func isFiller(_ text: String) -> Bool {
        let normalized = LiveTextNormalize.normalize(text)
        guard !normalized.isEmpty else { return false }
        if fillerPhrases.contains(normalized) { return true }
        let words = normalized.split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy { fillerPhrases.contains($0) }
    }
}
