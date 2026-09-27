// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import Darwin

public enum OfflineCoordinatorError: LocalizedError {
    case runtimeNotReady
    case jobAlreadyRunning
    case workerMissing

    public var errorDescription: String? {
        switch self {
        case .runtimeNotReady: return "The local runtime is not installed. Open Settings to install it."
        case .jobAlreadyRunning: return "Another local transcription is already running."
        case .workerMissing: return "The bundled offline transcription worker is missing."
        }
    }
}

/// What `OfflineJobCoordinator` needs from an app-managed local runtime.
/// `OfflineRuntimeManager` (Whisper) and `Qwen3ASRRuntimeManager` (Qwen3-ASR)
/// both provide it through their shared `ManagedOfflineRuntime` base.
@MainActor
public protocol OfflineTranscriptionRuntime: AnyObject {
    var state: OfflineRuntimeState { get }
    var pythonURL: URL { get }
    var modelURL: URL { get }
}
extension ManagedOfflineRuntime: OfflineTranscriptionRuntime {}

@MainActor
public final class OfflineJobCoordinator: ObservableObject {
    @Published public private(set) var jobs: [String: OfflineJobState] = [:]
    @Published public private(set) var activeSessionID: String?

    private let runtime: OfflineTranscriptionRuntime
    /// Resource name (without extension) of the `.py` worker bundled for this
    /// engine, e.g. "offline_worker" (Whisper) or "offline_worker_qwen" (Qwen3-ASR).
    private let workerResourceName: String
    private var process: Process?
    private var activeStore: OfflineJobStore?
    private var activeLogHandle: FileHandle?
    private var monitorTask: Task<Void, Never>?
    private var requestedStopStatus: OfflineJobStatus?

    public init(runtime: OfflineTranscriptionRuntime, workerResourceName: String = "offline_worker") {
        self.runtime = runtime
        self.workerResourceName = workerResourceName
    }

    public func state(for sessionID: String) -> OfflineJobState? { jobs[sessionID] }

    /// Rebuild the simple in-memory incomplete-job list. Heavy work never starts here.
    /// Walks subdirectories directly (rather than `MeetingStore.list`, which also
    /// stats audio/transcript/notes files and reads title files per folder) since
    /// only an offline-job state file per folder is needed here.
    ///
    /// The directory walk and per-folder state recovery are synchronous disk I/O
    /// that scale with meeting count, so they run off the main actor (mirroring
    /// `AppState.refresh()`); only the final assignment hops back to publish.
    ///
    /// Uses `OfflineJobStore.recoveredView()` (read-only) rather than
    /// `recover()`, which deletes temp files and rewrites `state.json` — a scan
    /// has no business mutating disk for a folder it isn't actively working
    /// on. `excludedSessionIDs` (plus this coordinator's own `activeSessionID`,
    /// always excluded) are skipped entirely and keep whatever is already in
    /// `jobs`, so a scan can never race — by reading stale/mid-write files, or
    /// by overwriting fresher in-memory progress with a stale on-disk read —
    /// the session an active worker is writing to. See P0-5.
    public func scan(outputDir: URL, excluding excludedSessionIDs: Set<String> = []) {
        let excluded = activeSessionID.map { excludedSessionIDs.union([$0]) } ?? excludedSessionIDs
        Task.detached(priority: .userInitiated) {
            let recovered = Self.scanSync(outputDir: outputDir, excluding: excluded)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var merged = recovered
                for id in excluded {
                    if let existing = self.jobs[id] { merged[id] = existing }
                }
                self.jobs = merged
            }
        }
    }

    private nonisolated static func scanSync(outputDir: URL, excluding excludedSessionIDs: Set<String>) -> [String: OfflineJobState] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var recovered: [String: OfflineJobState] = [:]
        for url in dirs {
            let sessionID = url.lastPathComponent
            guard !excludedSessionIDs.contains(sessionID) else { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let store = OfflineJobStore(sessionDir: url)
            guard fm.fileExists(atPath: store.stateURL.path),
                  let state = try? store.recoveredView() else { continue }
            recovered[sessionID] = state
        }
        return recovered
    }

    @discardableResult
    public func prepare(sessionDir: URL, config: OfflineJobConfig) async throws -> OfflineJobState {
        let store = OfflineJobStore(sessionDir: sessionDir)
        let state: OfflineJobState
        let expectedConfigID = offlineConfigID(engine: config.engine, model: config.model)
        if FileManager.default.fileExists(atPath: store.stateURL.path),
           let existing = try? store.recover(),
           existing.schemaVersion == 1, existing.configID == expectedConfigID {
            state = existing
        } else {
            state = try await store.create(config: config)
        }
        jobs[state.sessionID] = state
        return state
    }

    public func markSetupRequired(sessionDir: URL, config: OfflineJobConfig) async {
        do {
            var state = try await prepare(sessionDir: sessionDir, config: config)
            state.status = .failed
            state.lastError = "Local transcription runtime setup is required."
            try OfflineJobStore(sessionDir: sessionDir).save(state)
            jobs[state.sessionID] = state
        } catch { }
    }

    /// Start-over is explicit and user-confirmed by the caller. It removes only
    /// generated transcription state/output; meeting audio and sync files remain.
    public func resetTranscription(sessionDir: URL) throws {
        guard activeSessionID != sessionDir.lastPathComponent else {
            throw OfflineCoordinatorError.jobAlreadyRunning
        }
        try OfflineJobStore(sessionDir: sessionDir).clearGeneratedTranscription()
        jobs.removeValue(forKey: sessionDir.lastPathComponent)
    }

    public func start(sessionDir: URL, config: OfflineJobConfig) async throws {
        guard runtime.state == .ready else { throw OfflineCoordinatorError.runtimeNotReady }
        guard process == nil else { throw OfflineCoordinatorError.jobAlreadyRunning }
        guard let worker = Bundle.module.url(forResource: workerResourceName, withExtension: "py") else {
            throw OfflineCoordinatorError.workerMissing
        }

        let store = OfflineJobStore(sessionDir: sessionDir)
        var state = try await prepare(sessionDir: sessionDir, config: config)
        if state.status == .completed { return }
        state.status = .transcribing
        state.lastError = nil
        try store.save(state)
        jobs[state.sessionID] = state

        let workerProcess = Process()
        workerProcess.executableURL = runtime.pythonURL
        workerProcess.arguments = [worker.path, "--session-dir", sessionDir.path,
                                   "--model-dir", runtime.modelURL.path]
        // Redirect stdout/stderr to a per-meeting log (opened fresh, i.e.
        // truncated, at the start of each run) instead of /dev/null, so a
        // worker crash leaves something to diagnose beyond just an exit code.
        // See P2-5.
        var logHandle: FileHandle?
        do {
            try FileManager.default.createDirectory(at: store.transcriptionDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: store.workerLogURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.workerLogURL)
            logHandle = handle
            workerProcess.standardOutput = handle
            workerProcess.standardError = handle
            try workerProcess.run()
        } catch {
            try? logHandle?.close()
            state.status = .failed
            state.lastError = error.localizedDescription
            try? store.save(state)
            jobs[state.sessionID] = state
            throw error
        }

        process = workerProcess
        activeStore = store
        activeSessionID = state.sessionID
        activeLogHandle = logHandle
        requestedStopStatus = nil
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while workerProcess.isRunning && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self.reload(store: store)
            }
            guard !Task.isCancelled else { return }
            self.finish(process: workerProcess, store: store)
        }
    }

    public func pause() async { await stop(marking: .paused) }
    public func cancel() async { await stop(marking: .canceled) }
    public func stopForRecording() async { await stop(marking: .pending) }

    public func stop(marking status: OfflineJobStatus) async {
        guard let process else { return }
        requestedStopStatus = status
        process.terminate()
        let clock = ContinuousClock()
        let gracefulDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning && clock.now < gracefulDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // MLX may be inside native inference and unable to observe Python's
        // cooperative signal flag promptly. Part commits are atomic, so it is safe
        // to discard the current uncommitted chunk after a short grace period.
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if self.process != nil, let activeStore {
            finish(process: process, store: activeStore)
        }
    }

    private func reload(store: OfflineJobStore) {
        guard let state = try? store.load() else { return }
        jobs[state.sessionID] = state
    }

    private func finish(process finished: Process, store: OfflineJobStore) {
        guard process === finished else { return }
        monitorTask?.cancel()
        try? activeLogHandle?.close()
        activeLogHandle = nil
        let state = (try? store.load()) ?? jobs[activeSessionID ?? ""]
        if var current = state {
            if let requestedStopStatus {
                current.status = requestedStopStatus
                current.lastError = nil
            } else if finished.terminationStatus != 0 && current.status == .transcribing {
                current.status = .failed
                let tail = Self.tailOfWorkerLog(store: store)
                current.lastError = tail.isEmpty
                    ? "Local transcription worker exited (\(finished.terminationStatus))."
                    : "Local transcription worker exited (\(finished.terminationStatus)):\n\(tail)"
            }
            try? store.save(current)
            jobs[current.sessionID] = current
        }
        self.process = nil
        activeStore = nil
        activeSessionID = nil
        requestedStopStatus = nil
    }

    /// Last few lines of the worker's log (bounded), included in `lastError`
    /// on a non-zero exit so a crash leaves more than a bare exit code.
    private static func tailOfWorkerLog(store: OfflineJobStore, maxLines: Int = 12) -> String {
        guard let text = try? String(contentsOf: store.workerLogURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
    }
}
