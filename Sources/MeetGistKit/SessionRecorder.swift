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
        let stamp = df.string(from: Date())
        let detected = title ?? detectMeetingTitle()
        let name = detected.map { "\(stamp)-\($0)" } ?? stamp
        sessionDir = outputDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        systemURL = sessionDir.appendingPathComponent("system.m4a")
        micURL = sessionDir.appendingPathComponent("mic.m4a")
    }

    public func start() async throws {
        try await system.start(outputURL: systemURL)
        try mic.start(outputURL: micURL)
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
                               progress: @escaping @Sendable (String) -> Void) async throws -> PipelineResult {
        let mic = sessionDir.appendingPathComponent("mic.m4a")
        let system = sessionDir.appendingPathComponent("system.m4a")
        let micExists = AudioTools.isNonEmpty(mic)
        let systemExists = AudioTools.isNonEmpty(system)
        guard micExists || systemExists else {
            throw PipelineError.badResponse("no non-empty audio in session")
        }
        let result = try await pipeline.process(
            sessionDir: sessionDir, micExists: micExists, systemExists: systemExists,
            progress: progress)

        func write(_ s: String, _ name: String) throws {
            try (s + "\n").write(to: sessionDir.appendingPathComponent(name),
                                 atomically: true, encoding: .utf8)
        }
        try write(result.transcript, "transcript.md")
        try write(result.polished, "polished.md")
        try write(result.summary, "summary.md")
        let meta: [String: Any] = ["provider": pipeline.providerName, "model": result.model]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? d.write(to: sessionDir.appendingPathComponent("postprocess_meta.json"))
        }
        return result
    }
}
