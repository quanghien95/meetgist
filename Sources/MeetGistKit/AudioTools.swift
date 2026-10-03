// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import AVFoundation

/// Audio helpers via AVFoundation — replaces the Python pipeline's ffmpeg/afinfo/
/// ffprobe shell-outs so the app ships with no external binary dependencies.
public enum AudioTools {

    /// Duration in seconds, or nil if it can't be read.
    public static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration).seconds
            return d.isFinite && d >= 0 ? d : nil
        } catch {
            return nil
        }
    }

    /// True if the file exists and is larger than a tiny placeholder.
    public static func isNonEmpty(_ url: URL, minBytes: Int = 4096) -> Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int else { return false }
        return size >= minBytes
    }

    /// MIME type for the Gemini Files API, by extension.
    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    public enum ImportError: LocalizedError {
        case noAudioTrack

        public var errorDescription: String? {
            "The selected file has no audio track. Choose an audio file or a video with sound."
        }
    }

    /// Transcode audio from an audio or video file to m4a at `destination`.
    /// AppleM4A exports audio only, without copying or retaining video data.
    public static func export(_ source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ImportError.noAudioTrack
        }
        try Task.checkCancellation()
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "meetgist.audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "export session failed"])
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .m4a
        do {
            try await export.exportAsync()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public struct Chunk: Sendable {
        public let offsetSeconds: Double
        public let url: URL
    }

    /// Split `url` into `<= chunkSeconds` m4a slices in `workDir`. Long meetings are
    /// chunked so transcription doesn't hit model output limits. Returns the single
    /// original (offset 0) when it's short enough or can't be measured.
    public static func chunk(_ url: URL, chunkSeconds: Double, workDir: URL) async throws -> [Chunk] {
        guard let total = await duration(of: url), total > chunkSeconds else {
            return [Chunk(offsetSeconds: 0, url: url)]
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        var chunks: [Chunk] = []
        var start = 0.0
        var index = 0
        while start < total {
            let len = min(chunkSeconds, total - start)
            let out = workDir.appendingPathComponent(String(format: "chunk-%04d.m4a", index))
            try? FileManager.default.removeItem(at: out)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw NSError(domain: "meetgist.audio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "export session failed"])
            }
            export.outputURL = out
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: len, preferredTimescale: 600))
            try await export.exportAsync()
            if FileManager.default.fileExists(atPath: out.path) {
                chunks.append(Chunk(offsetSeconds: start, url: out))
            }
            start += chunkSeconds
            index += 1
        }
        return chunks.isEmpty ? [Chunk(offsetSeconds: 0, url: url)] : chunks
    }
}

extension AVAssetExportSession {
    /// macOS 14-compatible, cancellable wrapper around exportAsynchronously.
    /// Status/error are read after the export's completion callback resumes.
    func exportAsync() async throws {
        let operation = CancellableAssetExport(self)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                operation.start { cont.resume() }
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        if status != .completed {
            throw error ?? NSError(domain: "meetgist.audio", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "export status \(status.rawValue)"])
        }
    }
}

/// Serializes start/cancel so cancellation before the continuation is installed
/// cannot start an export afterwards. AVFoundation completes an active export's
/// callback when cancelExport() is called, allowing recording to await cleanup.
private final class CancellableAssetExport: @unchecked Sendable {
    private let export: AVAssetExportSession
    private let lock = NSLock()
    private var cancelled = false

    init(_ export: AVAssetExportSession) { self.export = export }

    func start(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { completion(); return }
        export.exportAsynchronously(completionHandler: completion)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        export.cancelExport()
    }
}
