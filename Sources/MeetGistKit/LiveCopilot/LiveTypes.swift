// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// MARK: - Live Meeting Copilot (V1/V2) core types
//
// Everything under `LiveCopilot/` is an optional, fully isolated path that
// runs alongside recording/transcription/notes (see docs/live-copilot-plan.md
// §4 "Isolation rule"). Nothing in this file or its siblings may be imported
// by `Recorder.swift`/`SessionRecorder.swift`/the notes pipeline; the wiring
// happens the other way (P3, app code, taps into this).

/// Which capture path a live turn came from. Named to match the plan's/UI's
/// vocabulary ("Speaker" / "Me") rather than reusing transcript-track name
/// strings used elsewhere in the codebase.
public enum LiveTrack: String, Codable, Sendable, CaseIterable {
    case speaker, me
}

/// Timings for one live turn, in host ticks (nanoseconds from
/// `mach_absolute_time`-derived host time, same clock as
/// `SessionRecorder.recordingAnchorHostNs`). Only `speechEndHostNs` is
/// guaranteed to be set as soon as the endpointer finalizes a segment; the
/// rest fill in as the turn moves through ASR and the semantic engine.
public struct LiveTurnTimings: Codable, Sendable, Equatable {
    public var speechEndHostNs: UInt64?
    public var asrStartHostNs: UInt64?
    public var asrEndHostNs: UInt64?
    public var llmStartHostNs: UInt64?
    public var llmEndHostNs: UInt64?
    /// Stamped by the app when the snapshot reflecting this turn is actually
    /// rendered — `LiveCopilotEngine` never sets this itself.
    public var uiUpdateHostNs: UInt64?

    public init(speechEndHostNs: UInt64? = nil, asrStartHostNs: UInt64? = nil,
                asrEndHostNs: UInt64? = nil, llmStartHostNs: UInt64? = nil,
                llmEndHostNs: UInt64? = nil, uiUpdateHostNs: UInt64? = nil) {
        self.speechEndHostNs = speechEndHostNs
        self.asrStartHostNs = asrStartHostNs
        self.asrEndHostNs = asrEndHostNs
        self.llmStartHostNs = llmStartHostNs
        self.llmEndHostNs = llmEndHostNs
        self.uiUpdateHostNs = uiUpdateHostNs
    }
}

/// One finalized, transcribed utterance on the live timeline.
public struct LiveTranscriptTurn: Codable, Sendable, Identifiable, Equatable {
    /// Monotonic per meeting (assigned by whatever ingests `SpeechSegment`s
    /// into transcriber calls — not by this type itself).
    public let id: Int
    public let track: LiveTrack
    /// Seconds since the recording anchor (`SessionRecorder.start()`), not
    /// wall-clock time — see plan §11 R5 for the known drift risk vs the
    /// final transcript's timestamps.
    public let startedAt: Double
    public let endedAt: Double
    public let text: String
    public var timings: LiveTurnTimings

    public init(id: Int, track: LiveTrack, startedAt: Double, endedAt: Double,
                text: String, timings: LiveTurnTimings = LiveTurnTimings()) {
        self.id = id
        self.track = track
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
        self.timings = timings
    }
}

/// One finalized utterance's audio, produced by `SpeechEndpointer` and handed
/// to a `RealtimeTranscriber`. Mono, 16 kHz, Float32 in [-1, 1].
public struct SpeechSegment: Sendable, Equatable {
    public let track: LiveTrack
    public let startedAt: Double
    public let endedAt: Double
    public let samples16k: [Float]

    public init(track: LiveTrack, startedAt: Double, endedAt: Double, samples16k: [Float]) {
        self.track = track
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples16k = samples16k
    }

    public var durationSeconds: Double { endedAt - startedAt }
}

/// Turns raw finalized speech audio into text. `QwenLiveTranscriber` is the
/// only conformer that may know anything about Qwen/mlx-audio — everything
/// above this protocol (the endpointer, the engine, the app) is
/// transcriber-agnostic.
public protocol RealtimeTranscriber: Sendable {
    var label: String { get }
    /// Loads the model once. Safe to call once per transcriber lifetime;
    /// `transcribe` must not be called before this completes.
    func prepare() async throws
    func transcribe(_ segment: SpeechSegment) async throws -> String
    /// Terminates any owned subprocess. Safe to call more than once.
    func shutdown() async
}

// MARK: - Future extension seam (plan §12 — do NOT implement V3/V4 logic now)

/// A bounded piece of evidence a V2 (Suggest Answer / Ask Meet Gist) or a
/// future V3 (Meeting Memory) request can cite. `source` is a short label
/// ("selected file", "5 min ago", a future retrieval source's name) shown
/// next to `from_context`/`known_from_meeting` claims — never raw file
/// content beyond what's already bounded into `text`.
public struct ContextSnippet: Sendable, Equatable {
    public let source: String
    public let text: String

    public init(source: String, text: String) {
        self.source = source
        self.text = text
    }
}

/// Seam for V2's manual file context (implemented in app code, P5) and a
/// possible future V3 retrieval provider (plan §12) — NOT implemented here.
/// `LiveCopilotEngine` accepts one of these but P1/P2 never calls it.
public protocol LiveContextProvider: Sendable {
    func snippets(forQuestion question: String) async throws -> [ContextSnippet]
}

// MARK: - P3 seam: audio sources (plan §5.10/§5.11)

/// One PCM chunk handed from a capture callback to a `LiveAudioSource`'s
/// `onChunk` closure. Always a fresh copy (never a reference into
/// capture-owned memory), interleaved if `channels > 1`. `hostTimeNs` is on
/// the same clock as `SessionRecorder.recordingAnchorHostNs`
/// (`DispatchTime`/mach-absolute-time nanoseconds).
public struct LivePCMChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channels: Int
    public let hostTimeNs: UInt64

    public init(samples: [Float], sampleRate: Double, channels: Int, hostTimeNs: UInt64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.hostTimeNs = hostTimeNs
    }
}

/// One PCM capture source `LiveAssistSession` (P3) taps: system audio
/// (`SystemAudioLiveSource`, wrapping `SessionRecorder`'s optional live PCM
/// sink) or the microphone (`LiveMicTap`, a dedicated `AVAudioEngine` input
/// tap — `MicRecorder`/`AVAudioRecorder` is never touched). A fake conformer
/// that calls `onChunk` directly with synthetic PCM is what makes
/// `LiveAssistSession` unit-testable without real audio, Python, or network.
public protocol LiveAudioSource: Sendable {
    /// Begins delivering PCM chunks to `onChunk` until `stop()`. A source
    /// that fails to start must throw rather than silently never calling
    /// `onChunk` — the caller (`LiveAssistSession`) decides what a failed
    /// source means for that track (plan §5.14: mic tap failure →
    /// Speaker-only live mode, never a crash and never touching recording).
    func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws
    /// Stops delivering chunks. Safe to call more than once and safe to call
    /// even if `start` was never called or failed.
    func stop() async
}
