// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Drives a recording session: creates the session folder, runs the system + mic
/// recorders, and writes `capture_timing.json` on stop. Shared by the app's UI.
public final class SessionRecorder: @unchecked Sendable {
    public let sessionDir: URL
    public let systemURL: URL
    public let micURL: URL

    private let system = SystemAudioRecorder()
    private let mic = MicRecorder()
    private let recordCommandStartHostNs = DispatchTime.now().uptimeNanoseconds
    private var stopRequestedHostNs: UInt64 = 0
    private var stopCompletedHostNs: UInt64 = 0

    public init(outputDir: URL, title: String? = nil) throws {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        df.locale = Locale(identifier: "en_US_POSIX")   // matches MeetingStore's parser
        let stamp = df.string(from: Date())
        let detected = title ?? detectMeetingTitle()
        let base = detected.map { "\(stamp)-\($0)" } ?? stamp
        sessionDir = try Self.makeSessionDir(outputDir: outputDir, base: base)
        if sessionDir.lastPathComponent != base {
            // A disambiguated folder ("…-2") would otherwise display its
            // numeric suffix as the title; pin the title the base name implies.
            try? (MeetingStore.prettyTitle(base) + "\n").write(
                to: sessionDir.appendingPathComponent(MeetingStore.titleFile), atomically: true, encoding: .utf8)
        }
        systemURL = sessionDir.appendingPathComponent("system.m4a")
        micURL = sessionDir.appendingPathComponent("mic.m4a")
    }

    /// Creates and returns a not-previously-existing folder named `base` under
    /// `outputDir`, disambiguating a collision (same minute + same/no detected
    /// title) by appending `-2`, `-3`, … `createDirectory(withIntermediateDirectories:
    /// false)` against the parent fails with "file exists" if the name is
    /// already taken, so looping on that error makes the check-and-create
    /// atomic-ish instead of the previous `withIntermediateDirectories: true`,
    /// which silently reused an existing folder — and `start()` then deleted
    /// its `system.m4a`/`mic.m4a` before recording into it.
    public static func makeSessionDir(outputDir: URL, base: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var suffix = 1
        while true {
            let candidate = suffix == 1 ? base : "\(base)-\(suffix)"
            let url = outputDir.appendingPathComponent(candidate)
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch {
                guard fm.fileExists(atPath: url.path) else { throw error }
                suffix += 1
            }
        }
    }

    public func start() async throws {
        try await system.start(outputURL: systemURL)
        do {
            try mic.start(outputURL: micURL)
        } catch {
            // Don't leave the ScreenCaptureKit stream (and its AVAssetWriter
            // against system.m4a in this now-abandoned session folder) running
            // if the mic half of the pair fails to start.
            try? await system.stop()
            throw error
        }
    }

    /// True once system audio is flowing (Screen Recording granted).
    public func systemReady() async -> Bool { await system.hasReceivedAudio() }
    /// Mic peak level in dBFS (≈ -160 = silent / no input).
    public func micLevel() -> Float { mic.peakLevel() }
    /// System-audio peak level in dBFS.
    public func systemLevel() async -> Float { await system.systemLevel() }

    /// Best-effort pause/resume (mic pauses; system drops buffers, leaving a gap).
    public func pause() { system.setPaused(true); mic.pause() }
    public func resume() { system.setPaused(false); mic.resume() }

    /// Host time this recorder was constructed — the anchor Live Assist's
    /// turn timestamps (`LiveTranscriptTurn.startedAt`/`endedAt`, every
    /// `LiveTurnTimings` field) are relative to (plan §5.10). Same clock
    /// (`DispatchTime`/mach-absolute-time nanoseconds) as every other host-ns
    /// value in the live path.
    public var recordingAnchorHostNs: UInt64 { recordCommandStartHostNs }

    /// Pass-through to the system recorder's optional live PCM sink (plan
    /// §5.10) — Live Assist's only hook into system-audio capture. `nil`
    /// restores byte-for-byte identical recording behavior.
    public func setLiveSystemSink(_ sink: (@Sendable (LivePCMChunk) -> Void)?) {
        system.setLivePCMSink(sink)
    }

    @discardableResult
    public func stop() async -> URL {
        stopRequestedHostNs = DispatchTime.now().uptimeNanoseconds
        try? await system.stop()
        mic.stop()
        stopCompletedHostNs = DispatchTime.now().uptimeNanoseconds
        let sysT = await system.timing()
        let micT = mic.timing()
        writeCaptureTiming(system: sysT, mic: micT)
        return sessionDir
    }

    private func writeCaptureTiming(system: [String: Any], mic: [String: Any]) {
        let payload: [String: Any] = [
            "schema_version": 1,
            "created_by": "meetgist",
            "session": [
                "session_dir": sessionDir.path,
                "record_command_start_host_ns": recordCommandStartHostNs,
                "stop_requested_host_ns": stopRequestedHostNs,
                "stop_completed_host_ns": stopCompletedHostNs,
            ],
            "system": system,
            "mic": mic,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sessionDir.appendingPathComponent("capture_timing.json"))
        }
    }
}

/// Runs the AI pipeline over a finished session and writes the Markdown outputs.
public enum MeetingProcessor {
    @discardableResult
    public static func process(sessionDir: URL,
                               pipeline: MeetingPipeline,
                               generateNotes: Bool = true,
                               progress: @escaping @Sendable (String) -> Void) async throws -> PipelineResult {
        let mic = sessionDir.appendingPathComponent("mic.m4a")
        let system = sessionDir.appendingPathComponent("system.m4a")
        let micExists = AudioTools.isNonEmpty(mic)
        let systemExists = AudioTools.isNonEmpty(system)
        guard micExists || systemExists else {
            throw PipelineError.badResponse("no non-empty audio in session")
        }

        func write(_ s: String, _ name: String) throws {
            try (s + "\n").write(to: sessionDir.appendingPathComponent(name),
                                 atomically: true, encoding: .utf8)
        }
        func writeMeta(model: String) {
            let meta: [String: Any] = ["provider": pipeline.providerName, "model": model]
            if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
                try? d.write(to: sessionDir.appendingPathComponent("postprocess_meta.json"))
            }
        }

        // Stage 1 — transcribe, then persist transcript.md immediately. This is
        // the durable artifact of a (possibly paid-for) transcription call; it
        // must survive even if the notes stage below throws, mirroring the
        // offline path, which already writes transcript.md before notes run.
        let (transcript, transcriberLabel) = try await pipeline.transcribe(
            sessionDir: sessionDir, micExists: micExists, systemExists: systemExists, progress: progress)
        try write(transcript, "transcript.md")

        // The transcript is now durable, so any persisted cloud-transcription
        // chunk checkpoint (see CloudTranscriptionCheckpoint) that fed it is
        // no longer needed — it's regenerable cache, not part of the
        // transcript contract, and could be sizeable for a long meeting.
        // Deleting it here (rather than keeping it around for a future
        // Regenerate) means a same-config re-run recomputes every chunk
        // instead of reusing stale ones; that's the safer default since nothing
        // stops a user from replacing/re-syncing audio in a session directory
        // between runs even though the ordinary app flow never does. This
        // never runs for the offline transcription path, which doesn't call
        // through `MeetingProcessor.process`.
        CloudTranscriptionCheckpoint.clearAll(sessionDir: sessionDir)

        guard generateNotes else {
            writeMeta(model: transcriberLabel)
            return PipelineResult(transcript: transcript, polished: "", summary: "", model: transcriberLabel)
        }

        // Stage 2 — same "transcript → polished/summary" contract as standalone
        // Generate/Regenerate. A failure here still leaves transcript.md on
        // disk and postprocess_meta.json unwritten, so the meeting shows the
        // transcript and the user can retry from Generate.
        let (polished, summary, notesLabel) = try await pipeline.writeNotes(
            transcript: transcript, progress: progress)
        try write(polished, "polished.md")
        try write(summary, "summary.md")
        let model = "\(transcriberLabel) → \(notesLabel)"
        writeMeta(model: model)
        return PipelineResult(transcript: transcript, polished: polished, summary: summary, model: model)
    }
}
