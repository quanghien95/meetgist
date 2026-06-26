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
}
