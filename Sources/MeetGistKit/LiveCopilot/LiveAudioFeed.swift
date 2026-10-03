// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation

/// Accepts raw PCM off a capture queue (the system-audio sample handler or
/// the mic tap's render callback), and off that caller's queue entirely,
/// downmixes to mono, resamples to 16 kHz, and delivers fixed-size frames to
/// a handler on its own serial queue. `ingest` only copies the caller's
/// buffer into a `Task`/`DispatchQueue.async` hand-off — the actual
/// downmix/resample/framing work never runs on the capture queue, matching
/// plan §5.1's isolation requirement ("never blocks `audioQueue` beyond a
/// copy").
///
/// Timestamping is best-effort: this feed keeps its own running clock in
/// seconds-since-anchor, seeded from the first buffer's host time and
/// advanced by exactly `frameSeconds` per emitted frame (not by re-deriving
/// host time per frame), which is precise enough for endpointing/turn
/// ordering but not sample-accurate sync (see plan §11 R5). All arithmetic
/// happens on the feed's own queue, so no locking is needed for the running
/// clock or the resampler's internal state.
public final class LiveAudioFeed: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (_ samples: [Float], _ startedAtSeconds: Double) -> Void

    public let track: LiveTrack
    private let targetSampleRate: Double
    private let frameSeconds: Double
    private let recordingAnchorHostNs: UInt64
    private let queue: DispatchQueue
    private let onFrame: FrameHandler

    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var pendingSamples: [Float] = []
    private var feedClockSeconds: Double?

    public init(track: LiveTrack, recordingAnchorHostNs: UInt64,
                targetSampleRate: Double = 16_000, frameSeconds: Double = 0.030,
                onFrame: @escaping FrameHandler) {
        self.track = track
        self.recordingAnchorHostNs = recordingAnchorHostNs
        self.targetSampleRate = targetSampleRate
        self.frameSeconds = frameSeconds
        self.queue = DispatchQueue(label: "meetgist.liveaudiofeed.\(track.rawValue)")
        self.onFrame = onFrame
    }

    /// `samples` is interleaved if `channels > 1`. `hostTimeNs` is this
    /// buffer's start time on the same clock as `recordingAnchorHostNs`
    /// (mach absolute time converted to nanoseconds).
    public func ingest(samples: [Float], sampleRate: Double, channels: Int, hostTimeNs: UInt64) {
        queue.async { [weak self] in
            self?.process(samples: samples, sampleRate: sampleRate, channels: channels, hostTimeNs: hostTimeNs)
        }
    }

    /// Resets internal framing/resampler state (e.g. after a pause/resume,
    /// where the next buffer isn't contiguous with the last one).
    public func reset() {
        queue.async { [weak self] in
            self?.pendingSamples.removeAll()
            self?.feedClockSeconds = nil
        }
    }

    private func process(samples: [Float], sampleRate: Double, channels: Int, hostTimeNs: UInt64) {
        let mono = Self.downmix(samples, channels: channels)
        let resampled = resample(mono, from: sampleRate)
        emitFrames(from: resampled, hostTimeNs: hostTimeNs)
    }

    static func downmix(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1, !samples.isEmpty else { return samples }
        let frameCount = samples.count / channels
        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i * channels + c] }
            out[i] = sum / Float(channels)
        }
        return out
    }

    private func resample(_ mono: [Float], from sampleRate: Double) -> [Float] {
        guard !mono.isEmpty else { return mono }
        guard abs(sampleRate - targetSampleRate) > 0.01 else { return mono }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)
        else { return mono }

        if converter == nil || converterSourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterSourceFormat = inputFormat
        }
        guard let converter,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return mono }
        inputBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, let dest = inputBuffer.floatChannelData?[0] else { return }
            dest.update(from: base, count: mono.count)
        }

        let ratio = targetSampleRate / sampleRate
        let outCapacity = AVAudioFrameCount((Double(mono.count) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return mono }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil, let data = outputBuffer.floatChannelData?[0] else { return mono }
        return Array(UnsafeBufferPointer(start: data, count: Int(outputBuffer.frameLength)))
    }

    private func emitFrames(from samples: [Float], hostTimeNs: UInt64) {
        if feedClockSeconds == nil {
            let elapsedNs = hostTimeNs >= recordingAnchorHostNs ? hostTimeNs - recordingAnchorHostNs : 0
            feedClockSeconds = Double(elapsedNs) / 1_000_000_000
        }
        pendingSamples.append(contentsOf: samples)
        let frameSampleCount = max(1, Int((targetSampleRate * frameSeconds).rounded()))
        while pendingSamples.count >= frameSampleCount {
            let frame = Array(pendingSamples.prefix(frameSampleCount))
            pendingSamples.removeFirst(frameSampleCount)
            let startedAt = feedClockSeconds!
            feedClockSeconds! += frameSeconds
            onFrame(frame, startedAt)
        }
    }
}
