// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation
import Darwin

/// Adapts `SessionRecorder`'s optional live PCM sink (plan §5.10) into the
/// `LiveAudioSource` seam `LiveAssistSession` (P3) drives. System audio is
/// already flowing (ScreenCaptureKit started it) by the time Live Assist
/// starts, so `start`/`stop` here only register/clear the sink — they never
/// start or stop capture itself, and `nil`-ing the sink restores
/// byte-for-byte identical `SystemAudioRecorder` behavior.
public final class SystemAudioLiveSource: LiveAudioSource, @unchecked Sendable {
    private let setSink: ((@Sendable (LivePCMChunk) -> Void)?) -> Void

    /// `setSink` is `SessionRecorder.setLiveSystemSink` (or a fake in tests).
    public init(setSink: @escaping ((@Sendable (LivePCMChunk) -> Void)?) -> Void) {
        self.setSink = setSink
    }

    public func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws {
        setSink(onChunk)
    }

    public func stop() async {
        setSink(nil)
    }
}

public enum LiveMicTapError: Error, LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Dedicated `AVAudioEngine` input tap feeding the mic ("Me") live track
/// (plan §5.10). Deliberately separate from `MicRecorder` (`AVAudioRecorder`,
/// unchanged). Apple's Voice Processing I/O removes loudspeaker echo before
/// audio reaches VAD/ASR. This live-only engine never plays captured audio.
/// Started only after `SessionRecorder.start()` succeeded and
/// stopped before `SessionRecorder.stop()`; any failure here must never
/// affect recording — the caller treats it as "Speaker-only live mode".
public final class LiveMicTap: LiveAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var started = false

    public init() {}

    public func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws {
        guard !started else { return }
        let input = engine.inputNode
        var tapInstalled = false
        do {
            // Enabling either I/O node enables both. Configure while stopped,
            // then query the processed OUTPUT format: VP may change it.
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = false
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            guard input.isVoiceProcessingEnabled, !input.isVoiceProcessingBypassed else {
                throw LiveMicTapError.unavailable("Microphone echo cancellation is unavailable for this audio device.")
            }
            let deviceFormat = input.outputFormat(forBus: 0)
            guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: deviceFormat.sampleRate, channels: 1, interleaved: false) else {
                throw LiveMicTapError.unavailable("Processed microphone format unavailable for Live Assist.")
            }
            // macOS VP can expose an aggregate with extra reference channels.
            // Request the processed mono uplink, never average that aggregate
            // back into Me (which would reintroduce system audio).
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                guard let chunk = Self.chunk(from: buffer, when: when) else { return }
                onChunk(chunk)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            guard AVCaptureDevice.activeMicrophoneMode != .wideSpectrum else {
                throw LiveMicTapError.unavailable("Choose Standard or Voice Isolation microphone mode to remove speaker echo.")
            }
            started = true
        } catch {
            if tapInstalled { input.removeTap(onBus: 0) }
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            // Never fall back silently to raw mic and reintroduce echoes.
            throw LiveMicTapError.unavailable("Live microphone echo cancellation could not start: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        started = false
    }

    private static func chunk(from buffer: AVAudioPCMBuffer, when: AVAudioTime) -> LivePCMChunk? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }
        var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
        if channelCount == 1 {
            interleaved.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                base.update(from: channelData[0], count: frameLength)
            }
        } else {
            for frame in 0..<frameLength {
                for ch in 0..<channelCount {
                    interleaved[frame * channelCount + ch] = channelData[ch][frame]
                }
            }
        }
        let hostTimeNs = when.isHostTimeValid ? hostTicksToNs(when.hostTime) : DispatchTime.now().uptimeNanoseconds
        return LivePCMChunk(samples: interleaved, sampleRate: buffer.format.sampleRate,
                            channels: channelCount, hostTimeNs: hostTimeNs)
    }

    private static let timebaseInfo: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// `AVAudioTime.hostTime` is raw mach-absolute-time ticks, not
    /// nanoseconds (unlike `DispatchTime.uptimeNanoseconds`, which already
    /// applies this conversion) — convert so every host-time value in the
    /// live path is on the same nanosecond clock.
    private static func hostTicksToNs(_ ticks: UInt64) -> UInt64 {
        guard timebaseInfo.denom != 0 else { return ticks }
        return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }
}
