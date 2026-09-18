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
        case .runtimeNotReady: return "Local Whisper is not installed. Open Settings to install it."
        case .jobAlreadyRunning: return "Another local transcription is already running."
        case .workerMissing: return "The bundled offline transcription worker is missing."
        }
    }
}

@MainActor
public final class OfflineJobCoordinator: ObservableObject {
    @Published public private(set) var jobs: [String: OfflineJobState] = [:]
    @Published public private(set) var activeSessionID: String?

    private let runtime: OfflineRuntimeManager
    private var process: Process?
    private var activeStore: OfflineJobStore?
    private var monitorTask: Task<Void, Never>?
    private var requestedStopStatus: OfflineJobStatus?

    public init(runtime: OfflineRuntimeManager) { self.runtime = runtime }

    public func state(for sessionID: String) -> OfflineJobState? { jobs[sessionID] }

    /// Rebuild the simple in-memory incomplete-job list. Heavy work never starts here.
    /// Walks subdirectories directly (rather than `MeetingStore.list`, which also
    /// stats audio/transcript/notes files and reads title files per folder) since
    /// only an offline-job state file per folder is needed here.
    public func scan(outputDir: URL) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var recovered: [String: OfflineJobState] = [:]
        for url in dirs {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let store = OfflineJobStore(sessionDir: url)
            guard fm.fileExists(atPath: store.stateURL.path),
                  let state = try? store.recover() else { continue }
            recovered[url.lastPathComponent] = state
        }
        jobs = recovered
    }

    @discardableResult
    public func prepare(sessionDir: URL, config: OfflineJobConfig) async throws -> OfflineJobState {
        let store = OfflineJobStore(sessionDir: sessionDir)
        let state: OfflineJobState
        if FileManager.default.fileExists(atPath: store.stateURL.path),
           let existing = try? store.recover(),
           existing.schemaVersion == 1, existing.configID == offlineConfigID {
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
            state.lastError = "Local Whisper setup is required."
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
        guard let worker = Bundle.module.url(forResource: "offline_worker", withExtension: "py") else {
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
        workerProcess.standardOutput = FileHandle.nullDevice
        workerProcess.standardError = FileHandle.nullDevice
        do {
            try workerProcess.run()
        } catch {
            state.status = .failed
            state.lastError = error.localizedDescription
            try? store.save(state)
            jobs[state.sessionID] = state
            throw error
        }

        process = workerProcess
        activeStore = store
        activeSessionID = state.sessionID
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
        let state = (try? store.load()) ?? jobs[activeSessionID ?? ""]
        if var current = state {
            if let requestedStopStatus {
                current.status = requestedStopStatus
                current.lastError = nil
            } else if finished.terminationStatus != 0 && current.status == .transcribing {
                current.status = .failed
                current.lastError = "Local transcription worker exited (\(finished.terminationStatus))."
            }
            try? store.save(current)
            jobs[current.sessionID] = current
        }
        self.process = nil
        activeStore = nil
        activeSessionID = nil
        requestedStopStatus = nil
    }
}
