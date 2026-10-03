// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox

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
    private var lastSystemPeakDb: Float = -160   // live level (dBFS), on audioQueue
    private var paused = false
    // Live Assist's optional, non-blocking PCM tap (plan §5.10). `nil` (the
    // default) means byte-for-byte identical behavior to before this existed
    // — the sample handler below only does the extra copy/callback when a
    // sink is set. Mutated only on `audioQueue`, same as `paused`.
    private var livePCMSink: (@Sendable (LivePCMChunk) -> Void)?

    /// Live system-audio peak in dBFS (≈ -160 = silent). Read on `audioQueue`.
    public func systemLevel() async -> Float {
        await withCheckedContinuation { cont in
            audioQueue.async { cont.resume(returning: self.paused ? -160 : self.lastSystemPeakDb) }
        }
    }

    /// While paused, buffers are dropped (leaving a silent gap in system.m4a).
    public func setPaused(_ p: Bool) { audioQueue.async { self.paused = p } }

    /// Registers (or clears, with `nil`) Live Assist's optional PCM tap (plan
    /// §5.10). Set on `audioQueue`, same queue the sample handler runs on, so
    /// there's no race between changing the sink and reading it per buffer.
    public func setLivePCMSink(_ sink: (@Sendable (LivePCMChunk) -> Void)?) {
        audioQueue.async { self.livePCMSink = sink }
    }

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

        updateSystemPeak(sampleBuffer)
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
        if !paused, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            buffersAppended += 1
        }

        // Live Assist's tap (plan §5.10): only when a sink is set and not
        // paused, after every existing append/level-metering step above —
        // a copy handed off immediately, no throwing, no shared locks with
        // the writer path.
        if !paused, let livePCMSink, let chunk = Self.pcmChunk(from: sampleBuffer, hostTimeNs: nowNs) {
            livePCMSink(chunk)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("scstream error: \(error)\n".utf8))
    }

    /// Compute a peak level from the PCM buffer (ScreenCaptureKit delivers Float32).
    private func updateSystemPeak(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        var bb: CMBlockBuffer?
        var abl = AudioBufferList()
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &bb)
        guard st == noErr else { return }
        var peak: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { peak = max(peak, abs(p[i])) }
        }
        lastSystemPeakDb = peak > 0 ? 20 * log10(peak) : -160
    }

    /// Copies the Float32 PCM out of `sb` for Live Assist's tap (review
    /// finding F2, fixed 2026-09-27). ScreenCaptureKit audio is commonly
    /// delivered as **non-interleaved** Float32 stereo — one `AudioBuffer`
    /// per channel, not one interleaved buffer. The previous version passed
    /// a single-`AudioBuffer`-sized list (`MemoryLayout<AudioBufferList>
    /// .size`) to `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`,
    /// which fails (`bufferListOut` too small) whenever CoreMedia actually
    /// hands back 2 non-interleaved buffers — silently returning `nil`, i.e.
    /// **no live system audio at all** — and even where it happened to
    /// succeed, concatenating per-channel buffers back to back and then
    /// treating that as interleaved data in `LiveAudioFeed.downmix` would
    /// have produced garbage (channel 1's tail averaged against channel 2's
    /// head).
    ///
    /// Fixed by: (1) querying `bufferListSizeNeededOut` first and allocating
    /// a correctly sized list via `AudioBufferList.allocate(maximumBuffers:)`
    /// (`mChannelsPerFrame` is always a safe upper bound: interleaved needs
    /// exactly 1 buffer, fully non-interleaved needs exactly `channels`);
    /// (2) checking `kAudioFormatFlagIsNonInterleaved` and, when set,
    /// averaging every channel's buffer per frame and emitting **mono
    /// directly** (`channels = 1`) instead of ever concatenating buffers —
    /// this is the only shape `LiveAudioFeed.downmix`/`resample` need to
    /// handle correctly regardless of the source layout. Interleaved input
    /// (single buffer) is copied through unchanged, exactly as before.
    ///
    /// This function only ever runs when `livePCMSink` is set (see the call
    /// site above) — with no sink, `stream(_:didOutputSampleBuffer:)`'s
    /// behavior is untouched, byte for byte.
    ///
    /// Deliberately **not** changed: `updateSystemPeak` above uses the same
    /// single-buffer pattern this function used to use, and is suspected of
    /// the same non-interleaved bug (the live system-level meter may read
    /// silence) — see docs/live-copilot-plan.md §11 for that follow-up; it's
    /// out of scope here per the "minimal Recorder.swift change" instruction
    /// and isn't part of the Live Assist PCM path this fixes.
    static func pcmChunk(from sb: CMSampleBuffer, hostTimeNs: UInt64) -> LivePCMChunk? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }

        var sizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        guard sizeStatus == noErr, sizeNeeded > 0 else { return nil }

        // Non-interleaved audio needs one `AudioBuffer` per channel;
        // interleaved needs exactly one — `mChannelsPerFrame` is a safe
        // upper bound either way.
        let maxBuffers = max(1, Int(asbd.mChannelsPerFrame))
        let listStorage = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(listStorage.unsafeMutablePointer) }

        var bb: CMBlockBuffer?
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: listStorage.unsafeMutablePointer,
            bufferListSize: sizeNeeded, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &bb)
        guard fillStatus == noErr else { return nil }

        let buffers = Array(UnsafeMutableAudioBufferListPointer(listStorage.unsafeMutablePointer))
        guard !buffers.isEmpty else { return nil }
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if !isNonInterleaved || buffers.count == 1 {
            // Single (interleaved, or already-mono) buffer — copy through
            // unchanged, exactly as the previous implementation did.
            guard let data = buffers[0].mData else { return nil }
            let n = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return nil }
            let p = data.assumingMemoryBound(to: Float.self)
            let samples = Array(UnsafeBufferPointer(start: p, count: n))
            let channels = max(1, Int(buffers[0].mNumberChannels))
            return LivePCMChunk(samples: samples, sampleRate: asbd.mSampleRate, channels: channels, hostTimeNs: hostTimeNs)
        }

        // Non-interleaved: one buffer per channel. Average across channels
        // per frame and emit mono directly (channels = 1) — never
        // concatenate buffers, which would be treated as interleaved
        // garbage downstream.
        let frameCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return nil }
        var channelPointers: [UnsafePointer<Float>] = []
        channelPointers.reserveCapacity(buffers.count)
        for buf in buffers {
            guard let data = buf.mData, Int(buf.mDataByteSize) / MemoryLayout<Float>.size == frameCount else { return nil }
            channelPointers.append(data.assumingMemoryBound(to: Float.self))
        }
        let scale = 1 / Float(channelPointers.count)
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for pointer in channelPointers { sum += pointer[i] }
            mono[i] = sum * scale
        }
        return LivePCMChunk(samples: mono, sampleRate: asbd.mSampleRate, channels: 1, hostTimeNs: hostTimeNs)
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

    public func pause() { recorder?.pause() }
    public func resume() { recorder?.record() }

    public func stop() {
        stopCalledHostNs = DispatchTime.now().uptimeNanoseconds
        recorder?.stop()
        recorder = nil
    }
}
