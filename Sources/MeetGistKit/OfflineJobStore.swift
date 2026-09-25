// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

public let offlineEngine = "mlx-whisper"
public let offlineModel = "mlx-community/whisper-large-v3-mlx"
public let offlineConfigID = "mlx-whisper-large-v3-v1"

public let qwenASREngine = "qwen3-asr"
public let qwenASRModel = "mlx-community/Qwen3-ASR-1.7B-4bit"

/// Namespaces cached transcription parts by engine+model so switching the
/// offline provider can never reuse another engine's incompatible output —
/// `isReusable` already checks `part.configID == state.configID`.
public func offlineConfigID(engine: String, model: String) -> String {
    let sanitizedModel = model.replacingOccurrences(of: "/", with: "-")
    return "\(engine)-\(sanitizedModel)-v1"
}

public enum OfflineJobStatus: String, Codable, Sendable, Equatable {
    case pending, transcribing, paused, completed, failed, canceled
}

public struct OfflineJobConfig: Codable, Sendable, Equatable {
    public var engine: String
    public var model: String
    public var language: String
    public var vocabulary: String
    public var chunkSeconds: Double
    public var overlapSeconds: Double

    public init(engine: String = offlineEngine, model: String = offlineModel,
                language: String = "auto", vocabulary: String = "",
                chunkSeconds: Double = 300, overlapSeconds: Double = 5) {
        self.engine = engine
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        self.chunkSeconds = chunkSeconds
        self.overlapSeconds = overlapSeconds
    }

    enum CodingKeys: String, CodingKey {
        case engine, model, language, vocabulary
        case chunkSeconds = "chunk_seconds"
        case overlapSeconds = "overlap_seconds"
    }
}

public struct OfflineTrackState: Codable, Sendable, Equatable {
    public var durationSeconds: Double
    public init(durationSeconds: Double) { self.durationSeconds = durationSeconds }
    enum CodingKeys: String, CodingKey { case durationSeconds = "duration_seconds" }
}

public struct OfflineJobProgress: Codable, Sendable, Equatable {
    public var processedSeconds: Double
    public var totalSeconds: Double
    public var trackProcessedSeconds: [String: Double]
    public var rollingRTF: Double?
    public var etaSeconds: Int?
    public var currentTrack: String?
    public var currentChunk: Int?

    public init(processedSeconds: Double = 0, totalSeconds: Double = 0,
                trackProcessedSeconds: [String: Double] = ["system": 0, "mic": 0],
                rollingRTF: Double? = nil, etaSeconds: Int? = nil,
                currentTrack: String? = nil, currentChunk: Int? = nil) {
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.trackProcessedSeconds = trackProcessedSeconds
        self.rollingRTF = rollingRTF
        self.etaSeconds = etaSeconds
        self.currentTrack = currentTrack
        self.currentChunk = currentChunk
    }

    public var fraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, processedSeconds / totalSeconds))
    }

    enum CodingKeys: String, CodingKey {
        case processedSeconds = "processed_seconds"
        case totalSeconds = "total_seconds"
        case trackProcessedSeconds = "track_processed_seconds"
        case rollingRTF = "rolling_rtf"
        case etaSeconds = "eta_seconds"
        case currentTrack = "current_track"
        case currentChunk = "current_chunk"
    }
}

public struct OfflineJobState: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var jobID: String
    public var sessionID: String
    public var status: OfflineJobStatus
    public var configID: String
    public var config: OfflineJobConfig
    public var tracks: [String: OfflineTrackState]
    public var progress: OfflineJobProgress
    public var lastError: String?
    public var warnings: [String]

    public init(jobID: String, sessionID: String, status: OfflineJobStatus = .pending,
                config: OfflineJobConfig, tracks: [String: OfflineTrackState]) {
        self.schemaVersion = 1
        self.jobID = jobID
        self.sessionID = sessionID
        self.status = status
        self.configID = offlineConfigID(engine: config.engine, model: config.model)
        self.config = config
        self.tracks = tracks
        self.progress = OfflineJobProgress(totalSeconds: tracks.values.reduce(0) { $0 + $1.durationSeconds })
        self.lastError = nil
        self.warnings = []
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case sessionID = "session_id"
        case status
        case configID = "config_id"
        case config, tracks, progress
        case lastError = "last_error"
        case warnings
    }
}

public struct OfflineSegment: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case text
    }
}

public struct OfflinePart: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var jobID: String
    public var sessionID: String
    public var configID: String
    public var track: String
    public var chunkIndex: Int
    public var coreStartSeconds: Double
    public var coreEndSeconds: Double
    public var processingSeconds: Double
    public var segments: [OfflineSegment]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case sessionID = "session_id"
        case configID = "config_id"
        case track
        case chunkIndex = "chunk_index"
        case coreStartSeconds = "core_start_seconds"
        case coreEndSeconds = "core_end_seconds"
        case processingSeconds = "processing_seconds"
        case segments
    }
}

public struct OfflineJobStore: Sendable {
    public let sessionDir: URL
    public var transcriptionDir: URL { sessionDir.appendingPathComponent("transcription", isDirectory: true) }
    public var partsDir: URL { transcriptionDir.appendingPathComponent("parts", isDirectory: true) }
    public var stateURL: URL { transcriptionDir.appendingPathComponent("state.json") }

    public init(sessionDir: URL) { self.sessionDir = sessionDir }

    public func load() throws -> OfflineJobState {
        try JSONDecoder().decode(OfflineJobState.self, from: Data(contentsOf: stateURL))
    }

    public func save(_ state: OfflineJobState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.atomicWrite(try encoder.encode(state), to: stateURL)
    }

    public func create(config: OfflineJobConfig) async throws -> OfflineJobState {
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        var tracks: [String: OfflineTrackState] = [:]
        for (name, file) in [("system", "system.m4a"), ("mic", "mic.m4a")] {
            let url = sessionDir.appendingPathComponent(file)
            if AudioTools.isNonEmpty(url), let duration = await AudioTools.duration(of: url), duration > 0 {
                tracks[name] = OfflineTrackState(durationSeconds: duration)
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let state = OfflineJobState(jobID: "offline-\(stamp)-\(UUID().uuidString.prefix(8))",
                                    sessionID: sessionDir.lastPathComponent,
                                    config: config, tracks: tracks)
        try save(state)
        return state
    }

    /// Repairs only the persisted v1 state: abandoned temporary files are removed,
    /// stale `transcribing` becomes `pending`, and progress is rebuilt from parts.
    public func recover() throws -> OfflineJobState {
        try removeTemporaryFiles()
        var state = try load()
        if state.status == .transcribing { state.status = .pending }
        var processedByTrack = ["system": 0.0, "mic": 0.0]
        var rtfs: [Double] = []
        for (track, trackState) in state.tracks {
            for interval in Self.chunks(duration: trackState.durationSeconds,
                                        chunkSeconds: state.config.chunkSeconds) {
                let url = partsDir.appendingPathComponent(String(format: "%@-%04d.json", track, interval.index))
                guard let data = try? Data(contentsOf: url),
                      let part = try? JSONDecoder().decode(OfflinePart.self, from: data),
                      Self.isReusable(part, for: state, track: track, interval: interval)
                else { continue }
                let core = interval.end - interval.start
                processedByTrack[track, default: 0] += core
                if core > 0 { rtfs.append(part.processingSeconds / core) }
            }
        }
        let processed = processedByTrack.values.reduce(0, +)
        let total = state.tracks.values.reduce(0) { $0 + $1.durationSeconds }
        let recent = rtfs.suffix(5)
        let rolling = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        state.progress = OfflineJobProgress(
            processedSeconds: processed, totalSeconds: total,
            trackProcessedSeconds: processedByTrack, rollingRTF: rolling,
            etaSeconds: rolling.map { Int(round(max(0, total - processed) * $0)) })
        try save(state)
        return state
    }

    public func removeTemporaryFiles() throws {
        guard FileManager.default.fileExists(atPath: transcriptionDir.path) else { return }
        let enumerator = FileManager.default.enumerator(at: transcriptionDir,
                                                        includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "tmp" { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Used only after the user confirms Re-transcribe. Canonical audio and sync
    /// metadata are deliberately outside these exact targets.
    public func clearGeneratedTranscription() throws {
        if FileManager.default.fileExists(atPath: transcriptionDir.path) {
            try FileManager.default.removeItem(at: transcriptionDir)
        }
        let transcript = sessionDir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: transcript.path) {
            try FileManager.default.removeItem(at: transcript)
        }
    }

    public static func chunks(duration: Double, chunkSeconds: Double) -> [(index: Int, start: Double, end: Double)] {
        guard duration > 0, chunkSeconds > 0 else { return [] }
        var result: [(Int, Double, Double)] = []
        var start = 0.0
        var index = 0
        while start < duration {
            result.append((index, start, min(duration, start + chunkSeconds)))
            start += chunkSeconds
            index += 1
        }
        return result
    }

    static func isReusable(_ part: OfflinePart, for state: OfflineJobState,
                           track: String, interval: (index: Int, start: Double, end: Double)) -> Bool {
        part.schemaVersion == 1 && part.jobID == state.jobID && part.sessionID == state.sessionID
            && part.configID == state.configID && part.track == track && part.chunkIndex == interval.index
            && abs(part.coreStartSeconds - interval.start) < 0.001
            && abs(part.coreEndSeconds - interval.end) < 0.001
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
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
