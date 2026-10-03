// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation
import CoreVideo

/// Real, synthetic media, isolated from the user's recordings. Tests inspect
/// the exported asset rather than inferring audio-only storage from its suffix.
enum MediaImportFixture {
    enum FixtureError: Error { case failed }

    static func video(in root: URL, extension ext: String = "mp4", withAudio: Bool = true) async throws -> URL {
        let video = root.appendingPathComponent("picture.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.failed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? FixtureError.failed
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                     nil, &pixel) == kCVReturnSuccess, let pixel else {
                throw FixtureError.failed
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let bytes = CVPixelBufferGetBaseAddress(pixel) {
                bytes.initializeMemory(as: UInt8.self, repeating: UInt8(frame * 8),
                                       count: CVPixelBufferGetBytesPerRow(pixel) * 64)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? FixtureError.failed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.failed }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let targetVideo = composition.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FixtureError.failed
        }
        let duration = try await videoAsset.load(.duration)
        try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        if withAudio {
            let audio = root.appendingPathComponent("tone.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.2)
            }
            // Close the WAV writer before opening it as an AVURLAsset.
            do {
                let file = try AVAudioFile(forWriting: audio, settings: format.settings)
                try file.write(from: buffer)
            }
            let encoded = root.appendingPathComponent("tone.m4a")
            try await export(AVURLAsset(url: audio), preset: AVAssetExportPresetAppleM4A, to: encoded, type: .m4a)
            let audioAsset = AVURLAsset(url: encoded)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            guard let sourceAudio = audioTracks.first,
                  let targetAudio = composition.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FixtureError.failed
            }
            try targetAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)
        }
        let output = root.appendingPathComponent("meeting.\(ext)")
        try await export(composition, preset: AVAssetExportPresetPassthrough,
                         to: output, type: ext == "mov" ? .mov : .mp4)
        return output
    }

    private static func export(_ asset: AVAsset, preset: String, to output: URL, type: AVFileType) async throws {
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { throw FixtureError.failed }
        export.outputURL = output
        export.outputFileType = type
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else { throw export.error ?? FixtureError.failed }
    }
}
