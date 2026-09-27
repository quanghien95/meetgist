// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import Darwin
import CryptoKit

/// Builds the config id that namespaces persisted cloud-transcription chunks
/// under a meeting directory (see `CloudTranscriptionCheckpoint`). It must
/// fold in every provider/model/option that changes transcription output —
/// style (gemini/whisper), model, base URL (a custom base URL can point at a
/// different deployment of the "same" model), the chunk length, and any
/// prompt-affecting toggle a caller passes in `options` (e.g. which tracks
/// exist, since that changes both the Gemini prompt and the Whisper speaker
/// labels) — so switching provider, model, or those options never reuses a
/// stale chunk from a different config, mirroring `offlineConfigID`'s role
/// for the offline engines.
public func cloudTranscriptionConfigID(style: String, model: String, baseURL: String,
                                       chunkSeconds: Double, options: [String] = []) -> String {
    func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "&", with: "-")
    }
    var parts = [sanitize(style), sanitize(model), sanitize(baseURL), "chunk\(Int(chunkSeconds))"]
    parts.append(contentsOf: options.map(sanitize))
    let id = parts.joined(separator: "_")
    // It becomes a directory name: keep it well under the 255-byte limit even
    // for a long custom base URL, while staying unique per config.
    guard id.utf8.count > 120 else { return id }
    let digest = SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(sanitize(style))_\(String(sanitize(model).prefix(60)))_\(digest)"
}

/// Persists successfully transcribed cloud-transcription chunks under
/// `<sessionDir>/cloud-transcription/<configID>/<track>-<index>.txt` so a
/// re-run after a failed chunk (e.g. chunk 8 of 10, after `HTTPRetry`'s
/// retries are exhausted) doesn't re-call — and re-pay for — chunks already
/// transcribed. `configID` namespaces the directory the same way
/// `OfflineJobStore` namespaces its parts by engine+model: a different
/// provider/model/base URL/chunk length never reuses another config's chunks.
///
/// Deliberately smaller than `OfflineJobStore`: cloud transcription is a
/// single linear pass over a fixed list of chunks (no pause/resume mid-chunk,
/// no separate progress/state machine), so one atomically-written text file
/// per unit is enough — no JSON state file is needed because the directory
/// name already carries the full config and existence of a well-formed
/// `<track>-<index>.txt` file is itself "this chunk is committed".
public struct CloudTranscriptionCheckpoint: Sendable {
    public let sessionDir: URL
    public let configID: String

    public init(sessionDir: URL, configID: String) {
        self.sessionDir = sessionDir
        self.configID = configID
    }

    /// Parent of every config's checkpoint directory. Removed wholesale on a
    /// successful run (see `MeetingProcessor.process`) since it's regenerable
    /// cache, not part of the transcript contract.
    public var rootDirectory: URL {
        sessionDir.appendingPathComponent("cloud-transcription", isDirectory: true)
    }

    public var directory: URL {
        rootDirectory.appendingPathComponent(configID, isDirectory: true)
    }

    private func fileURL(track: String, index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%@-%04d.txt", track, index))
    }

    /// Previously-committed text for this unit, or `nil` if there is nothing
    /// to reuse (never transcribed, a different config, or a leftover `.tmp`
    /// from an interrupted write — a `.tmp` file is never read as committed
    /// output, so a cancelled/crashed write can never be mistaken for a
    /// finished chunk).
    public func load(track: String, index: Int) -> String? {
        guard let data = try? Data(contentsOf: fileURL(track: track, index: index)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Atomically persists `text` for this unit: write to a sibling `.tmp`,
    /// fsync, then `rename` over the destination. `rename` is atomic on
    /// APFS/HFS+, so a crash or cancellation mid-write never leaves a
    /// half-written file that a later run could reuse (see `load`, which
    /// only ever reads the final, non-`.tmp` path).
    public func save(_ text: String, track: String, index: Int) throws {
        try Self.atomicWrite(Data(text.utf8), to: fileURL(track: track, index: index))
    }

    /// Deletes every persisted chunk for every config under this session.
    /// Called only after `transcript.md` has been durably written (see
    /// `MeetingProcessor.process`) — it's a large, fully-regenerable cache,
    /// not the canonical transcript, so it's fine to drop once the run that
    /// needed it has already succeeded. Best-effort: a failed cleanup must
    /// never fail an otherwise-successful transcription.
    public func clearAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    /// Convenience for callers that only need to clear the cache (they don't
    /// have a specific `configID` in hand, e.g. `MeetingProcessor.process`
    /// right after a successful transcribe) — deletes the whole
    /// `cloud-transcription` tree for `sessionDir`, every config included.
    public static func clearAll(sessionDir: URL) {
        CloudTranscriptionCheckpoint(sessionDir: sessionDir, configID: "").clearAll()
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("tmp")
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Runs a resumable, checkpointed sequence of cloud-transcription chunk calls
/// for one track (a Gemini "window" spanning all tracks, or one Whisper
/// track's chunk list — see `GeminiTranscriber`/`WhisperTranscriber`). Each
/// unit is identified by `(track, index)`; a unit already committed under
/// `checkpoint`'s config is reused without invoking `compute` again, so a
/// re-run only calls the API for chunks that are still missing. Reports once,
/// up front, how many chunks were reused.
///
/// Factored out from the two transcribers so the resumability logic itself is
/// unit-testable with a fake `compute` closure — no network, no real audio.
enum CloudChunkTranscription {
    static func run(
        checkpoint: CloudTranscriptionCheckpoint,
        track: String,
        count: Int,
        progress: @escaping @Sendable (String) -> Void,
        compute: @Sendable (_ index: Int) async throws -> String
    ) async throws -> [String] {
        guard count > 0 else { return [] }

        var cached = [String?](repeating: nil, count: count)
        var reusedCount = 0
        for i in 0..<count {
            if let text = checkpoint.load(track: track, index: i) {
                cached[i] = text
                reusedCount += 1
            }
        }
        if reusedCount > 0 {
            progress("Reusing \(reusedCount) of \(count) transcribed chunks…")
        }

        var results = [String](repeating: "", count: count)
        for i in 0..<count {
            try Task.checkCancellation()
            if let text = cached[i] {
                results[i] = text
                continue
            }
            let text = try await compute(i)
            try checkpoint.save(text, track: track, index: i)
            results[i] = text
        }
        return results
    }
}
