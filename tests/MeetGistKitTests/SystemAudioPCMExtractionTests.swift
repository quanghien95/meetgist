// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import CoreMedia
import AudioToolbox
@testable import MeetGistKit

/// Regression tests for review finding F2: `SystemAudioRecorder.pcmChunk`
/// used to pass a single-`AudioBuffer`-sized `AudioBufferList` to
/// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, which fails
/// (returning `nil`, i.e. no live system audio at all) whenever
/// ScreenCaptureKit delivers non-interleaved Float32 stereo (one `AudioBuffer`
/// per channel — common for `SCStream` audio), and even a hypothetical
/// success path would have concatenated per-channel buffers and treated the
/// result as interleaved, producing garbage. These tests build real
/// `CMSampleBuffer`s for both layouts (via `CMSampleBufferSetDataBufferFromAudioBufferList`,
/// the standard inverse of the API `pcmChunk` calls) and assert correct,
/// non-garbage mono extraction.
@Suite struct SystemAudioPCMExtractionTests {
    private enum BuildError: Error { case failed(String) }

    /// Builds a real Float32 `CMSampleBuffer` with either an interleaved
    /// single buffer or one non-interleaved buffer per channel, with sample
    /// values `channelValue(channel, frame)` so tests can assert on exact
    /// content (not just "didn't crash").
    private func makeSampleBuffer(interleaved: Bool, channelCount: Int, sampleRate: Double,
                                   frameCount: Int, channelValue: (Int, Int) -> Float) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved }
        asbd.mBitsPerChannel = 32
        asbd.mChannelsPerFrame = UInt32(channelCount)
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = interleaved ? UInt32(channelCount * 4) : 4
        asbd.mBytesPerPacket = asbd.mBytesPerFrame

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let formatDescription else {
            throw BuildError.failed("CMAudioFormatDescriptionCreate failed: \(formatStatus)")
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        guard createStatus == noErr, let sampleBuffer else {
            throw BuildError.failed("CMSampleBufferCreate failed: \(createStatus)")
        }

        if interleaved {
            var samples = [Float](repeating: 0, count: frameCount * channelCount)
            for f in 0..<frameCount {
                for c in 0..<channelCount { samples[f * channelCount + c] = channelValue(c, f) }
            }
            let status = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                let audioBuffer = AudioBuffer(mNumberChannels: UInt32(channelCount),
                                              mDataByteSize: UInt32(ptr.count * MemoryLayout<Float>.size),
                                              mData: UnsafeMutableRawPointer(ptr.baseAddress))
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                return CMSampleBufferSetDataBufferFromAudioBufferList(
                    sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, bufferList: &list)
            }
            guard status == noErr else { throw BuildError.failed("SetDataBufferFromAudioBufferList (interleaved) failed: \(status)") }
        } else {
            var channelStorage: [[Float]] = (0..<channelCount).map { c in (0..<frameCount).map { f in channelValue(c, f) } }
            let listStorage = AudioBufferList.allocate(maximumBuffers: channelCount)
            defer { free(listStorage.unsafeMutablePointer) }
            listStorage.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channelCount)
            let status: OSStatus = try channelStorage.withUnsafeMutableBufferPointer { channels -> OSStatus in
                for c in 0..<channelCount {
                    guard let base = channels[c].withUnsafeMutableBufferPointer({ $0.baseAddress }) else {
                        throw BuildError.failed("nil channel buffer")
                    }
                    listStorage[c] = AudioBuffer(mNumberChannels: 1,
                                                 mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                                                 mData: UnsafeMutableRawPointer(base))
                }
                return CMSampleBufferSetDataBufferFromAudioBufferList(
                    sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, bufferList: listStorage.unsafeMutablePointer)
            }
            guard status == noErr else { throw BuildError.failed("SetDataBufferFromAudioBufferList (non-interleaved) failed: \(status)") }
        }
        return sampleBuffer
    }

    @Test func interleavedStereoIsCopiedThroughUnchanged() throws {
        let sb = try makeSampleBuffer(interleaved: true, channelCount: 2, sampleRate: 48_000, frameCount: 4) { c, f in
            Float(c == 0 ? f + 1 : -(f + 1)) // L: 1,2,3,4  R: -1,-2,-3,-4
        }
        let chunk = SystemAudioRecorder.pcmChunk(from: sb, hostTimeNs: 42)
        let unwrapped = try #require(chunk)
        #expect(unwrapped.channels == 2)
        #expect(unwrapped.sampleRate == 48_000)
        #expect(unwrapped.hostTimeNs == 42)
        #expect(unwrapped.samples == [1, -1, 2, -2, 3, -3, 4, -4])
    }

    /// The core F2 regression: 2 non-interleaved buffers used to make the
    /// old single-buffer-sized `AudioBufferList` call fail outright (nil
    /// chunk, no audio at all). It must now succeed and, per the finding's
    /// fix, emit mono (channels == 1) as the exact per-frame average of the
    /// two channel buffers — not a concatenation.
    @Test func nonInterleavedStereoProducesCorrectMonoAverageNotGarbage() throws {
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [3, 4, 5, 6]
        let sb = try makeSampleBuffer(interleaved: false, channelCount: 2, sampleRate: 16_000, frameCount: 4) { c, f in
            c == 0 ? left[f] : right[f]
        }
        let chunk = SystemAudioRecorder.pcmChunk(from: sb, hostTimeNs: 7)
        let unwrapped = try #require(chunk)
        #expect(unwrapped.channels == 1)
        #expect(unwrapped.sampleRate == 16_000)
        #expect(unwrapped.samples.count == 4)
        for i in 0..<4 {
            #expect(abs(unwrapped.samples[i] - (left[i] + right[i]) / 2) < 0.0001)
        }
        // Never the buggy "concatenate then downmix as interleaved" shape —
        // that would have been 8 samples, or (left[i] + left[i+... ])/2, etc.
        #expect(unwrapped.samples != left + right)
    }

    @Test func nonInterleavedMonoSingleBufferIsCopiedThroughUnchanged() throws {
        let sb = try makeSampleBuffer(interleaved: false, channelCount: 1, sampleRate: 16_000, frameCount: 3) { _, f in Float(f) * 0.5 }
        let chunk = SystemAudioRecorder.pcmChunk(from: sb, hostTimeNs: 1)
        let unwrapped = try #require(chunk)
        #expect(unwrapped.channels == 1)
        #expect(unwrapped.samples == [0, 0.5, 1.0])
    }

    @Test func nonInterleavedThreeChannelAveragesAllChannelsPerFrame() throws {
        let sb = try makeSampleBuffer(interleaved: false, channelCount: 3, sampleRate: 48_000, frameCount: 2) { c, f in
            Float((c + 1) * 10 + f)
        }
        let chunk = SystemAudioRecorder.pcmChunk(from: sb, hostTimeNs: 0)
        let unwrapped = try #require(chunk)
        #expect(unwrapped.channels == 1)
        // frame 0: (10 + 20 + 30) / 3 = 20 ; frame 1: (11 + 21 + 31) / 3 = 21
        #expect(abs(unwrapped.samples[0] - 20) < 0.0001)
        #expect(abs(unwrapped.samples[1] - 21) < 0.0001)
    }
}
