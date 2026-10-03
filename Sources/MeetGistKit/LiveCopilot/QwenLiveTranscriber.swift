// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

public enum QwenLiveTranscriberError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case timeout
    case dropped
    case workerFailed(String)
    case notReady

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .timeout: return "Live transcription timed out"
        case .dropped: return "Live transcription segment dropped (queue overflow)"
        case .workerFailed(let message): return "Live ASR worker error: \(message)"
        case .notReady: return "Live ASR worker is not ready"
        }
    }
}

/// Persistent per-recording worker wrapping `live_asr_worker.py` (plan
/// §5.3): the model loads once, then every finalized `SpeechSegment` is one
/// JSON-lines request/response pair over the worker's stdin/stdout. Nothing
/// outside this file may know the wire protocol or that Qwen/mlx-audio is the
/// engine underneath — `RealtimeTranscriber` is the only contract the rest
/// of the Kit sees.
public actor QwenLiveTranscriber: RealtimeTranscriber {
    public struct Config: Sendable {
        public var pythonURL: URL
        public var workerScriptURL: URL
        public var modelDirURL: URL
        public var language: String?
        public var hotwordsFileURL: URL?
        public var prepareTimeout: TimeInterval
        public var requestTimeout: TimeInterval
        public var maxPendingSegments: Int
        public var logURL: URL?

        public init(pythonURL: URL, workerScriptURL: URL, modelDirURL: URL, language: String? = nil,
                    hotwordsFileURL: URL? = nil, prepareTimeout: TimeInterval = 90,
                    requestTimeout: TimeInterval = 10, maxPendingSegments: Int = 4, logURL: URL? = nil) {
            self.pythonURL = pythonURL
            self.workerScriptURL = workerScriptURL
            self.modelDirURL = modelDirURL
            self.language = language
            self.hotwordsFileURL = hotwordsFileURL
            self.prepareTimeout = prepareTimeout
            self.requestTimeout = requestTimeout
            self.maxPendingSegments = maxPendingSegments
            self.logURL = logURL
        }
    }

    private struct QueuedRequest {
        let id: Int
        let track: LiveTrack
        let segment: SpeechSegment
        let continuation: CheckedContinuation<String, Error>
    }

    public nonisolated let label = "Qwen3-ASR Live"

    private let config: Config
    private let workDir: URL

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stderrRing: [String] = []

    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var startupFailure: Error?

    private var queue: [QueuedRequest] = []
    private var dispatchedRequest: (id: Int, continuation: CheckedContinuation<String, Error>, pcmPath: URL)?
    private var nextID = 0
    private var droppedCount = 0

    public init(config: Config) {
        self.config = config
        self.workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-live-asr-\(UUID().uuidString)", isDirectory: true)
    }

    /// Resolves the bundled `live_asr_worker.py` inside `MeetGistKit`'s own
    /// resource bundle. App code (a different module/target) can't reach
    /// `Bundle.module` directly — this is the same pattern
    /// `OfflineJobCoordinator` uses internally for `offline_worker*.py`, just
    /// exposed publicly since Live Assist's worker process is started from
    /// `AppState+LiveAssist.swift`, not from inside this Kit.
    public static func resolveWorkerScriptURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "live_asr_worker", withExtension: "py") else {
            throw QwenLiveTranscriberError.unavailable("Bundled live_asr_worker.py is missing.")
        }
        return url
    }

    // MARK: - RealtimeTranscriber

    public func prepare() async throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = config.pythonURL
        var arguments = ["-u", config.workerScriptURL.path, "--model-dir", config.modelDirURL.path]
        if let language = config.language, !language.isEmpty, language != "auto" {
            arguments += ["--language", language]
        }
        if let hotwordsFileURL = config.hotwordsFileURL {
            arguments += ["--hotwords-file", hotwordsFileURL.path]
        }
        process.arguments = arguments

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            throw QwenLiveTranscriberError.unavailable("Could not start the live ASR worker: \(error.localizedDescription)")
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        readerTask = Task { [weak self] in
            await self?.readLoop(stdoutPipe.fileHandleForReading)
        }
        stderrTask = Task { [weak self] in
            await self?.stderrLoop(stderrPipe.fileHandleForReading)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if isReady { continuation.resume(); return }
            if let startupFailure { continuation.resume(throwing: startupFailure); return }
            readyWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.config.prepareTimeout ?? 90) * 1_000_000_000)
                await self?.failReadyWaitersOnTimeout()
            }
        }
    }

    public func transcribe(_ segment: SpeechSegment) async throws -> String {
        guard startupFailure == nil else { throw startupFailure! }
        enforceCapacity()
        return try await withCheckedThrowingContinuation { continuation in
            let id = nextID
            nextID += 1
            queue.append(QueuedRequest(id: id, track: segment.track, segment: segment, continuation: continuation))
            dispatchNextIfIdle()
        }
    }

    public func shutdown() async {
        readyWaiters.forEach { $0.resume(throwing: QwenLiveTranscriberError.unavailable("shutting down")) }
        readyWaiters.removeAll()
        for request in queue { request.continuation.resume(throwing: QwenLiveTranscriberError.dropped) }
        queue.removeAll()
        if let dispatched = dispatchedRequest {
            dispatched.continuation.resume(throwing: QwenLiveTranscriberError.dropped)
            dispatchedRequest = nil
        }
        if let stdinHandle {
            let message = (try? JSONSerialization.data(withJSONObject: ["type": "shutdown"])) ?? Data()
            try? stdinHandle.write(contentsOf: message + Data([0x0A]))
        }
        guard let process else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            if Darwin.kill(-pid, SIGTERM) != 0 { process.terminate() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning {
                if Darwin.kill(-pid, SIGKILL) != 0 { Darwin.kill(pid, SIGKILL) }
            }
        }
        try? stdinHandle?.close()
        readerTask?.cancel()
        stderrTask?.cancel()
        writeLogIfNeeded()
        try? FileManager.default.removeItem(at: workDir)
        self.process = nil
    }

    // MARK: - Bounded queue

    /// Drops the oldest queued mic segment first, else the oldest queued
    /// segment overall (plan §5.3) — only ever from `queue` (not-yet-
    /// dispatched requests); a request already sent to the worker is left to
    /// finish or time out.
    private func enforceCapacity() {
        let occupied = queue.count + (dispatchedRequest == nil ? 0 : 1)
        guard occupied >= config.maxPendingSegments else { return }
        guard !queue.isEmpty else { return }
        let dropIndex = queue.firstIndex(where: { $0.track == .me }) ?? queue.startIndex
        let dropped = queue.remove(at: dropIndex)
        droppedCount += 1
        dropped.continuation.resume(throwing: QwenLiveTranscriberError.dropped)
    }

    private func dispatchNextIfIdle() {
        guard dispatchedRequest == nil, isReady, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let pcmPath = workDir.appendingPathComponent("\(next.id).f32")
        do {
            try Self.writeFloat32LE(next.segment.samples16k, to: pcmPath)
        } catch {
            next.continuation.resume(throwing: error)
            dispatchNextIfIdle()
            return
        }
        dispatchedRequest = (next.id, next.continuation, pcmPath)
        let payload: [String: Any] = [
            "type": "transcribe", "id": next.id, "pcm_path": pcmPath.path, "sample_rate": 16_000,
        ]
        guard let stdinHandle, let data = try? JSONSerialization.data(withJSONObject: payload) else {
            failDispatched(with: QwenLiveTranscriberError.unavailable("worker stdin unavailable"))
            return
        }
        do {
            try stdinHandle.write(contentsOf: data + Data([0x0A]))
        } catch {
            failDispatched(with: error)
            return
        }
        let requestID = next.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.config.requestTimeout ?? 10) * 1_000_000_000))
            await self?.timeoutIfStillDispatched(requestID)
        }
    }

    private func timeoutIfStillDispatched(_ id: Int) {
        guard dispatchedRequest?.id == id else { return }
        failDispatched(with: QwenLiveTranscriberError.timeout)
    }

    private func failDispatched(with error: Error) {
        guard let dispatched = dispatchedRequest else { return }
        dispatchedRequest = nil
        try? FileManager.default.removeItem(at: dispatched.pcmPath)
        dispatched.continuation.resume(throwing: error)
        dispatchNextIfIdle()
    }

    private func completeDispatched(id: Int, text: String?, errorMessage: String?) {
        guard let dispatched = dispatchedRequest, dispatched.id == id else { return }
        dispatchedRequest = nil
        try? FileManager.default.removeItem(at: dispatched.pcmPath)
        if let errorMessage {
            dispatched.continuation.resume(throwing: QwenLiveTranscriberError.workerFailed(errorMessage))
        } else {
            dispatched.continuation.resume(returning: text ?? "")
        }
        dispatchNextIfIdle()
    }

    // MARK: - Worker I/O

    private func readLoop(_ handle: FileHandle) async {
        var buffer = Data()
        while true {
            let chunk = await Self.readAvailable(handle)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                handleLine(lineData)
            }
        }
        handleWorkerStreamClosed()
    }

    private func stderrLoop(_ handle: FileHandle) async {
        var buffer = Data()
        while true {
            let chunk = await Self.readAvailable(handle)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    stderrRing.append(line)
                    if stderrRing.count > 200 { stderrRing.removeFirst(stderrRing.count - 200) }
                }
            }
        }
    }

    private nonisolated static func readAvailable(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
        case "result":
            guard let id = obj["id"] as? Int else { return }
            completeDispatched(id: id, text: obj["text"] as? String, errorMessage: nil)
        case "error":
            guard let id = obj["id"] as? Int else { return }
            completeDispatched(id: id, text: nil, errorMessage: (obj["message"] as? String) ?? "unknown error")
        default:
            break
        }
    }

    private func handleWorkerStreamClosed() {
        guard startupFailure == nil else { return }
        let failure = QwenLiveTranscriberError.unavailable("Live ASR worker exited unexpectedly")
        startupFailure = failure
        readyWaiters.forEach { $0.resume(throwing: failure) }
        readyWaiters.removeAll()
        if let dispatched = dispatchedRequest {
            dispatchedRequest = nil
            try? FileManager.default.removeItem(at: dispatched.pcmPath)
            dispatched.continuation.resume(throwing: failure)
        }
        for request in queue { request.continuation.resume(throwing: failure) }
        queue.removeAll()
    }

    private func handleTermination() {
        handleWorkerStreamClosed()
    }

    private func failReadyWaitersOnTimeout() {
        guard !isReady, !readyWaiters.isEmpty else { return }
        let failure = QwenLiveTranscriberError.unavailable("Live ASR worker did not become ready in time")
        startupFailure = failure
        readyWaiters.forEach { $0.resume(throwing: failure) }
        readyWaiters.removeAll()
    }

    private func writeLogIfNeeded() {
        guard let logURL = config.logURL, !stderrRing.isEmpty else { return }
        let text = stderrRing.joined(separator: "\n") + "\n"
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Apple Silicon is little-endian, so a plain byte-copy of native `Float`
    /// storage already produces the little-endian Float32 file the worker
    /// protocol expects (plan §5.3) — no manual byte-swapping needed.
    private static func writeFloat32LE(_ samples: [Float], to url: URL) throws {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }
}
