// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Tunable start values for `SpeechEndpointer` (plan §5.1). All durations are
/// seconds; `sampleRate`/`frameSeconds` together fix `frameSamples`, the exact
/// sample count `process(frame:atSeconds:)` expects per call.
public struct LiveEndpointerConfig: Sendable, Equatable {
    public var sampleRate: Double
    public var frameSeconds: Double
    /// Margin above the adaptive noise floor a frame's RMS must exceed to
    /// count as speech, floored at `absoluteFloorDBFS` in a silent room.
    public var floorMarginDB: Double
    public var absoluteFloorDBFS: Double
    /// EMA smoothing applied to the noise floor on every *quiet* frame only.
    public var noiseFloorEMAAlpha: Double
    /// Start: at least this much voiced time within `startWindowSeconds`.
    public var startVoicedSeconds: Double
    public var startWindowSeconds: Double
    /// Audio kept before the detected start (whether voiced or not).
    public var preRollSeconds: Double
    /// End: this much continuous silence closes the segment (trailing
    /// silence is trimmed back to the last voiced frame).
    public var hangoverSeconds: Double
    /// After this much open segment duration, end at the first pause of at
    /// least `softMaxPauseSeconds` instead of waiting for the full hangover.
    public var softMaxSeconds: Double
    public var softMaxPauseSeconds: Double
    /// Absolute cap: force-cut even mid-speech rather than let one speaker
    /// monopolize the endpointer forever.
    public var hardMaxSeconds: Double
    /// Segments with less voiced audio than this are discarded entirely.
    public var minVoicedSeconds: Double

    // Latency-first defaults (2026-09-27 decision, plan §3 "latency first"):
    // the post-meeting pipeline already produces the accurate
    // transcript/notes, so Live Assist favors shorter turns/faster cuts over
    // maximally clean segmentation.
    public init(sampleRate: Double = 16_000, frameSeconds: Double = 0.030,
                floorMarginDB: Double = 10, absoluteFloorDBFS: Double = -50,
                noiseFloorEMAAlpha: Double = 0.05,
                startVoicedSeconds: Double = 0.150, startWindowSeconds: Double = 0.300,
                preRollSeconds: Double = 0.300, hangoverSeconds: Double = 0.600,
                softMaxSeconds: Double = 15, softMaxPauseSeconds: Double = 0.250,
                hardMaxSeconds: Double = 30, minVoicedSeconds: Double = 0.500) {
        self.sampleRate = sampleRate
        self.frameSeconds = frameSeconds
        self.floorMarginDB = floorMarginDB
        self.absoluteFloorDBFS = absoluteFloorDBFS
        self.noiseFloorEMAAlpha = noiseFloorEMAAlpha
        self.startVoicedSeconds = startVoicedSeconds
        self.startWindowSeconds = startWindowSeconds
        self.preRollSeconds = preRollSeconds
        self.hangoverSeconds = hangoverSeconds
        self.softMaxSeconds = softMaxSeconds
        self.softMaxPauseSeconds = softMaxPauseSeconds
        self.hardMaxSeconds = hardMaxSeconds
        self.minVoicedSeconds = minVoicedSeconds
    }

    /// Exact sample count one `process(frame:atSeconds:)` call must receive.
    public var frameSamples: Int { max(1, Int((sampleRate * frameSeconds).rounded())) }
}

/// Energy-based voice activity detector + segmenter (plan §5.1). Pure and
/// synchronous by design: it knows nothing about queues, host time, or
/// Foundation I/O, so every rule (start/end/soft-max/hard-max/discard) is
/// unit-testable by feeding synthetic frames. `LiveAudioFeed` is the only
/// caller — it does the resampling/framing and supplies each frame's
/// meeting-relative start time.
public struct SpeechEndpointer: Sendable {
    private struct BufferedFrame {
        let samples: [Float]
        let startSeconds: Double
        let isSpeech: Bool
    }

    public let track: LiveTrack
    public let config: LiveEndpointerConfig

    private var noiseFloorDBFS: Double = -60
    private var preroll: [BufferedFrame] = []
    private var isOpen = false
    private var openSamples: [Float] = []
    private var openStartSeconds: Double = 0
    private var openLastVoicedEndSeconds: Double = 0
    private var voicedAccumulatedSeconds: Double = 0
    private var silenceRunSeconds: Double = 0

    public init(track: LiveTrack, config: LiveEndpointerConfig = LiveEndpointerConfig()) {
        self.track = track
        self.config = config
    }

    /// Feeds one frame of mono samples (exactly `config.frameSamples` long)
    /// starting at `atSeconds` (seconds since the recording anchor). Frames
    /// must arrive in non-decreasing time order. Returns a finalized segment
    /// if this frame closed one (by hangover, soft max, or hard max) and it
    /// met `minVoicedSeconds`; discarded segments return `nil` silently.
    public mutating func process(frame: [Float], atSeconds: Double) -> SpeechSegment? {
        let frameDuration = Double(frame.count) / config.sampleRate
        let dbfs = Self.dbfs(frame)
        let isSpeech = dbfs > max(noiseFloorDBFS + config.floorMarginDB, config.absoluteFloorDBFS)
        if !isSpeech {
            noiseFloorDBFS = noiseFloorDBFS * (1 - config.noiseFloorEMAAlpha) + dbfs * config.noiseFloorEMAAlpha
        }

        if !isOpen {
            return processWhileIdle(frame: frame, atSeconds: atSeconds, frameDuration: frameDuration, isSpeech: isSpeech)
        }
        return processWhileOpen(frame: frame, atSeconds: atSeconds, frameDuration: frameDuration, isSpeech: isSpeech)
    }

    /// Finalizes any open segment immediately (recording paused/stopped).
    /// Drops any accumulated pre-roll since there's nothing to attach it to.
    public mutating func flush() -> SpeechSegment? {
        preroll.removeAll()
        guard isOpen else { return nil }
        return finalize(endSeconds: openLastVoicedEndSeconds)
    }

    // MARK: - Idle (pre-speech) state

    private mutating func processWhileIdle(frame: [Float], atSeconds: Double, frameDuration: Double, isSpeech: Bool) -> SpeechSegment? {
        preroll.append(BufferedFrame(samples: frame, startSeconds: atSeconds, isSpeech: isSpeech))
        let windowStart = atSeconds + frameDuration - config.startWindowSeconds
        preroll.removeAll { $0.startSeconds < windowStart - config.preRollSeconds }

        let voicedInWindow = preroll
            .filter { $0.startSeconds >= windowStart }
            .reduce(0.0) { $0 + ($1.isSpeech ? Double($1.samples.count) / config.sampleRate : 0) }
        guard voicedInWindow >= config.startVoicedSeconds else { return nil }

        // Open the segment, carrying every buffered frame within
        // `preRollSeconds` of now (voiced or not) as pre-roll context.
        let rollStart = atSeconds + frameDuration - config.preRollSeconds
        let kept = preroll.filter { $0.startSeconds >= rollStart }
        openStartSeconds = kept.first?.startSeconds ?? atSeconds
        openSamples = kept.flatMap(\.samples)
        voicedAccumulatedSeconds = kept.reduce(0.0) { $0 + ($1.isSpeech ? Double($1.samples.count) / config.sampleRate : 0) }
        openLastVoicedEndSeconds = kept.last(where: { $0.isSpeech }).map { $0.startSeconds + Double($0.samples.count) / config.sampleRate }
            ?? (atSeconds + frameDuration)
        silenceRunSeconds = 0
        isOpen = true
        preroll.removeAll()
        return nil
    }

    // MARK: - Open (in-speech) state

    private mutating func processWhileOpen(frame: [Float], atSeconds: Double, frameDuration: Double, isSpeech: Bool) -> SpeechSegment? {
        openSamples.append(contentsOf: frame)
        let frameEnd = atSeconds + frameDuration
        if isSpeech {
            voicedAccumulatedSeconds += frameDuration
            openLastVoicedEndSeconds = frameEnd
            silenceRunSeconds = 0
        } else {
            silenceRunSeconds += frameDuration
        }
        let openDuration = frameEnd - openStartSeconds

        if openDuration >= config.hardMaxSeconds {
            return finalize(endSeconds: frameEnd)
        }
        if silenceRunSeconds >= config.hangoverSeconds {
            return finalize(endSeconds: openLastVoicedEndSeconds)
        }
        if openDuration >= config.softMaxSeconds && silenceRunSeconds >= config.softMaxPauseSeconds {
            return finalize(endSeconds: openLastVoicedEndSeconds)
        }
        return nil
    }

    private mutating func finalize(endSeconds: Double) -> SpeechSegment? {
        defer {
            isOpen = false
            openSamples = []
            voicedAccumulatedSeconds = 0
            silenceRunSeconds = 0
        }
        guard voicedAccumulatedSeconds >= config.minVoicedSeconds else { return nil }
        let end = max(endSeconds, openStartSeconds)
        let keepSamples = min(openSamples.count, max(0, Int(((end - openStartSeconds) * config.sampleRate).rounded())))
        let trimmed = Array(openSamples.prefix(keepSamples))
        return SpeechSegment(track: track, startedAt: openStartSeconds, endedAt: end, samples16k: trimmed)
    }

    // MARK: - Energy

    static func dbfs(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return -120 }
        var sumSquares: Double = 0
        for sample in frame { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(frame.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }
}
