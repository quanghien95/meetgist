// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - System audio via ScreenCaptureKit

public final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public override init() { super.init() }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    // All writer/input mutation happens on this queue, which is also the
    // SCStream sample handler queue — so audio callbacks and stop() can't race.
    private let audioQueue = DispatchQueue(label: "meetgist.audio")

    // Phase-1 dual-file sync anchors (host ns via DispatchTime.now().uptimeNanoseconds).
    // Buffer fields are mutated only on audioQueue; the two start anchors are set
    // once before any buffer arrives. See dual-file-sync-engineering-plan.md.
    private var requestedStartHostNs: UInt64 = 0
    private var streamStartedHostNs: UInt64 = 0
    private var firstBufferHostNs: UInt64 = 0
    private var firstBufferPtsSeconds: Double = 0
    private var lastBufferHostNs: UInt64 = 0
    private var lastBufferPtsSeconds: Double = 0
    private var buffersAppended: Int = 0

    public func start(outputURL: URL) async throws {
        requestedStartHostNs = DispatchTime.now().uptimeNanoseconds
        try? FileManager.default.removeItem(at: outputURL)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "meetgist", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display found"])
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let excludeApps = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludeApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Video is required by SCStream even when we only want audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "meetgist", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "can't add audio input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "meetgist", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }

        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        streamStartedHostNs = DispatchTime.now().uptimeNanoseconds
        self.stream = stream
    }

    /// Phase-1 sync metadata for the system track. Read on `audioQueue` so the
    /// buffer counters can't race the sample handler. Call after `stop()`.
    public func timing() async -> [String: Any] {
        await withCheckedContinuation { cont in
            audioQueue.async {
                let status: String
                switch self.writer?.status {
                case .completed: status = "completed"
                case .failed: status = "failed"
                case .cancelled: status = "cancelled"
                case .writing: status = "writing"
                default: status = "unknown"
                }
                cont.resume(returning: [
                    "file": "system.m4a",
                    "requested_start_host_ns": self.requestedStartHostNs,
                    "stream_started_host_ns": self.streamStartedHostNs,
                    "first_buffer_host_ns": self.firstBufferHostNs,
                    "first_buffer_pts_seconds": self.firstBufferPtsSeconds,
                    "last_buffer_host_ns": self.lastBufferHostNs,
                    "last_buffer_pts_seconds": self.lastBufferPtsSeconds,
                    "buffers_appended": self.buffersAppended,
                    "sample_rate": 48000,
                    "channels": 2,
                    "writer_status": status,
                    "error": NSNull(),
                ])
            }
        }
    }

    /// True once ScreenCaptureKit has delivered at least one valid audio buffer.
    /// Read on `audioQueue` so it can't race the sample handler. A buffer arrives
    /// on a steady cadence as soon as capture works (even during silence), so this
    /// flips to true unless the pipeline is dead — e.g. Screen Recording denied.
    public func hasReceivedAudio() async -> Bool {
        await withCheckedContinuation { cont in
            audioQueue.async { cont.resume(returning: self.sessionStarted) }
        }
    }

    public func stop() async throws {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        // Drain the audio queue so no in-flight callback can append after we
        // mark the input finished, then capture the writer reference.
        let w: AVAssetWriter? = await withCheckedContinuation { cont in
            audioQueue.async {
                self.input?.markAsFinished()
                cont.resume(returning: self.writer)
            }
        }
        if let w = w {
            await w.finishWriting()
        }
    }

    // MARK: SCStreamOutput (invoked on audioQueue)
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let writer = writer, let input = input else { return }
        if writer.status == .failed || writer.status == .cancelled { return }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let pts = sampleBuffer.presentationTimeStamp.seconds
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
            firstBufferHostNs = nowNs
            firstBufferPtsSeconds = pts.isFinite ? pts : 0
        }
        lastBufferHostNs = nowNs
        if pts.isFinite { lastBufferPtsSeconds = pts }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            buffersAppended += 1
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("scstream error: \(error)\n".utf8))
    }
}

// MARK: - Microphone via AVAudioRecorder

public final class MicRecorder {
    public init() {}

    private var recorder: AVAudioRecorder?

    // Phase-1 sync anchors. AVAudioRecorder gives no per-sample timestamps, so
    // these are coarse start/stop call anchors (confidence "coarse"). Phase 4 of
    // the sync plan upgrades the mic to buffer-level timing.
    private var requestedStartHostNs: UInt64 = 0
    private var recordStartedHostNs: UInt64 = 0
    private var stopCalledHostNs: UInt64 = 0

    public func start(outputURL: URL) throws {
        requestedStartHostNs = DispatchTime.now().uptimeNanoseconds
        try? FileManager.default.removeItem(at: outputURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64000
        ]
        let rec = try AVAudioRecorder(url: outputURL, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord(), rec.record() else {
            throw NSError(domain: "meetgist", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "mic record() failed"])
        }
        recordStartedHostNs = DispatchTime.now().uptimeNanoseconds
        recorder = rec
    }

    /// Phase-1 sync metadata for the mic track. Call after `stop()`.
    public func timing() -> [String: Any] {
        [
            "file": "mic.m4a",
            "requested_start_host_ns": requestedStartHostNs,
            "record_started_host_ns": recordStartedHostNs,
            "stop_called_host_ns": stopCalledHostNs,
            "sample_rate": 48000,
            "channels": 1,
            "recorder_status": recordStartedHostNs == 0 ? "error" : "completed",
            "error": NSNull(),
        ]
    }

    /// Peak input level in dBFS. Around the floor (≈ -120 dB and below) means
    /// digital silence — mic muted or Microphone permission denied. Returns the
    /// floor if not recording.
    public func peakLevel() -> Float {
        guard let recorder = recorder, recorder.isRecording else { return -160 }
        recorder.updateMeters()
        return recorder.peakPower(forChannel: 0)
    }

    public func stop() {
        stopCalledHostNs = DispatchTime.now().uptimeNanoseconds
        recorder?.stop()
        recorder = nil
    }
}
