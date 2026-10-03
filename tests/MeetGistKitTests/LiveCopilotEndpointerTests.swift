// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct LiveCopilotEndpointerTests {
    /// Synthesizes `count` frames of either loud speech-level or silent
    /// samples, one `LiveEndpointerConfig.frameSamples`-sized array per call.
    private static func frame(_ config: LiveEndpointerConfig, loud: Bool) -> [Float] {
        let amplitude: Float = loud ? 0.5 : 0.0001
        return [Float](repeating: amplitude, count: config.frameSamples)
    }

    @Test func defaultContinuousSpeechPublishesWithinTwentySeconds() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var first: SpeechSegment?
        for index in 0..<Int(21 / config.frameSeconds) {
            if let segment = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: Double(index) * config.frameSeconds) {
                first = segment
                break
            }
        }
        #expect(first != nil)
        #expect((first?.endedAt ?? 100) <= 20 + config.frameSeconds)
        #expect((first?.durationSeconds ?? 100) >= 19.8)
    }

    @Test func defaultKeepsSixHundredMillisecondClausePauseWithinOneTurn() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var segments: [SpeechSegment] = []
        var time = 0.0
        for (seconds, loud) in [(1.0, true), (0.6, false), (1.0, true), (1.0, false)] {
            for _ in 0..<Int(seconds / config.frameSeconds) {
                if let segment = endpointer.process(frame: Self.frame(config, loud: loud), atSeconds: time) { segments.append(segment) }
                time += config.frameSeconds
            }
        }
        #expect(segments.count == 1)
        #expect((segments.first?.durationSeconds ?? 0) > 2.4)
    }

    @Test func continuousSpeechThenSilenceFinalizesOneTurn() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []

        // ~1s of loud speech.
        for _ in 0..<Int(1.0 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        // Silence past the hangover threshold.
        for _ in 0..<Int((config.hangoverSeconds + 0.2) / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: false), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }

        #expect(segments.count == 1)
        let segment = try! #require(segments.first)
        #expect(segment.track == .speaker)
        #expect(segment.durationSeconds >= 0.5)
        #expect(!segment.samples16k.isEmpty)
    }

    @Test func shortFragmentsWithBriefGapsMergeIntoOneTurn() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []

        func speak(_ seconds: Double) {
            for _ in 0..<Int(seconds / config.frameSeconds) {
                if let seg = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t) { segments.append(seg) }
                t += config.frameSeconds
            }
        }
        func pause(_ seconds: Double) {
            for _ in 0..<Int(seconds / config.frameSeconds) {
                if let seg = endpointer.process(frame: Self.frame(config, loud: false), atSeconds: t) { segments.append(seg) }
                t += config.frameSeconds
            }
        }

        speak(0.5)
        pause(0.3)   // well under hangoverSeconds — must not end the turn
        speak(0.5)
        pause(config.hangoverSeconds + 0.2)

        #expect(segments.count == 1)
    }

    @Test func silenceOnlyNeverFinalizesASegment() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []
        for _ in 0..<Int(3.0 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: false), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        #expect(segments.isEmpty)
        #expect(endpointer.flush() == nil)
    }

    @Test func softMaxCutsAtFirstPauseAfterThreshold() {
        var config = LiveEndpointerConfig()
        config.softMaxSeconds = 2.0
        config.softMaxPauseSeconds = 0.25
        config.hardMaxSeconds = 100
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []

        // Speak continuously past softMaxSeconds.
        for _ in 0..<Int(2.5 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        // A short pause at/above softMaxPauseSeconds but well under the full hangover.
        for _ in 0..<Int(0.28 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: false), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }

        #expect(segments.count == 1)
        let segment = try! #require(segments.first)
        #expect(segment.durationSeconds < config.hangoverSeconds + 2.5)
    }

    @Test func hardMaxForceCutsEvenDuringContinuousSpeech() {
        var config = LiveEndpointerConfig()
        config.hardMaxSeconds = 3.0
        config.softMaxSeconds = 100   // disabled relative to this test's duration
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []
        // Speak continuously, no pauses at all, well past hardMaxSeconds.
        for _ in 0..<Int(4.0 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        #expect(segments.count == 1)
        let segment = try! #require(segments.first)
        #expect(segment.durationSeconds <= config.hardMaxSeconds + config.frameSeconds)
    }

    @Test func shortNoiseBelowMinVoicedIsDiscarded() {
        var config = LiveEndpointerConfig()
        config.minVoicedSeconds = 0.5
        config.hangoverSeconds = 0.2
        var endpointer = SpeechEndpointer(track: .speaker, config: config)
        var t = 0.0
        var segments: [SpeechSegment] = []
        // Barely satisfies the start condition (150ms voiced) then immediately
        // goes silent — total voiced time stays under minVoicedSeconds.
        for _ in 0..<Int(0.18 / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        for _ in 0..<Int((config.hangoverSeconds + 0.2) / config.frameSeconds) {
            if let seg = endpointer.process(frame: Self.frame(config, loud: false), atSeconds: t) { segments.append(seg) }
            t += config.frameSeconds
        }
        #expect(segments.isEmpty)
    }

    @Test func pauseFlushFinalizesAnOpenSegment() {
        let config = LiveEndpointerConfig()
        var endpointer = SpeechEndpointer(track: .me, config: config)
        var t = 0.0
        for _ in 0..<Int(1.0 / config.frameSeconds) {
            _ = endpointer.process(frame: Self.frame(config, loud: true), atSeconds: t)
            t += config.frameSeconds
        }
        let flushed = endpointer.flush()
        #expect(flushed != nil)
        #expect(flushed?.track == .me)
        // A second flush with nothing open returns nil.
        #expect(endpointer.flush() == nil)
    }
}
