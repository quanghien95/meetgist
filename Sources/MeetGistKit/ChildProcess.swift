// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// Shared child-process supervision, used everywhere MeetGist spawns a
/// `Process` it must be able to cancel or bound in time: launches the
/// process, drains its stdout/stderr concurrently on background threads
/// (so output beyond the pipe buffer — ~64KB on macOS — can never deadlock
/// the parent the way blocking `waitUntilExit()` before draining does),
/// honors Swift Task cancellation, and supports an optional wall-clock
/// timeout. Termination is graceful-then-forced: SIGTERM, a short grace
/// period, then SIGKILL — previously reimplemented separately by
/// `CodexProcessController` and `QwenProcessController`.
public enum ChildProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        /// True if `stdout`/`stderr` hit `capturedBytesLimit` and further
        /// output was discarded (the pipe was still drained so the child
        /// never blocked on a full pipe buffer).
        public let stdoutTruncated: Bool
        public let stderrTruncated: Bool
        /// True if `timeout` elapsed and the process was stopped.
        public let timedOut: Bool
    }

    /// Bytes captured per stream before further output is discarded.
    public static let defaultCapturedBytesLimit = 1 << 20   // 1 MB

    /// Runs `process` to completion. Sets `process.standardOutput`/
    /// `standardError` itself (a pipe each) — do not set them beforehand.
    /// `process.standardInput`, `executableURL`, `arguments`, and
    /// `environment` should already be configured by the caller.
    /// `keepTail` keeps the last `capturedBytesLimit` bytes of each stream
    /// instead of the first — for callers that only report the output's tail
    /// (e.g. the final lines of a failing worker's log).
    public static func run(_ process: Process,
                           timeout: TimeInterval? = nil,
                           capturedBytesLimit: Int = defaultCapturedBytesLimit,
                           keepTail: Bool = false) async throws -> Result {
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Draining happens on its own background thread per stream,
        // independent of both `process.run()` and the termination wait below,
        // so a child that writes megabytes to either stream is always read as
        // it arrives rather than backing up the pipe.
        async let stdoutCapture = Self.drain(stdoutPipe.fileHandleForReading, limit: capturedBytesLimit, keepTail: keepTail)
        async let stderrCapture = Self.drain(stderrPipe.fileHandleForReading, limit: capturedBytesLimit, keepTail: keepTail)

        let controller = ChildProcessController(process: process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    controller.didFinish()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    controller.didStart()
                    if let timeout { controller.armTimeout(seconds: timeout) }
                } catch {
                    // The child never started, so nothing else will close the
                    // write ends; close them so both drains see EOF instead of
                    // blocking forever while this scope awaits them.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            controller.cancel()
        }

        // Both drains finish only once the child's pipes hit EOF, which
        // happens after it fully exits (or is killed) — safe to await here
        // alongside (not before) the termination status above.
        let (out, err) = await (stdoutCapture, stderrCapture)
        try Task.checkCancellation()
        return Result(status: status, stdout: out.data, stderr: err.data,
                     stdoutTruncated: out.truncated, stderrTruncated: err.truncated,
                     timedOut: controller.timedOut)
    }

    private static func drain(_ handle: FileHandle, limit: Int, keepTail: Bool) async -> (data: Data, truncated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                var truncated = false
                while true {
                    // Blocks until data arrives or the write end closes (EOF),
                    // at which point it returns empty Data.
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if keepTail {
                        buffer.append(chunk)
                        if buffer.count > limit {
                            buffer = Data(buffer.suffix(limit))
                            truncated = true
                        }
                    } else if buffer.count < limit {
                        let room = limit - buffer.count
                        if chunk.count > room {
                            buffer.append(chunk.prefix(room))
                            truncated = true
                        } else {
                            buffer.append(chunk)
                        }
                    } else {
                        truncated = true
                    }
                }
                continuation.resume(returning: (buffer, truncated))
            }
        }
    }
}

/// Cancel → SIGTERM → 2s grace → SIGKILL, plus an optional timer-based
/// timeout for subprocesses that can hang with no output at all (no bytes to
/// detect a stall from, unlike a stuck decode loop).
final class ChildProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var canceled = false
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private(set) var timedOut = false

    init(process: Process) { self.process = process }

    func didStart() {
        lock.lock()
        let shouldCancel = canceled
        lock.unlock()
        if shouldCancel { stop() }
    }

    func armTimeout(seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.fireTimeout() }
        lock.lock()
        if finished { lock.unlock(); return }
        timeoutWorkItem = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fireTimeout() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        timedOut = true
        let running = process.isRunning
        lock.unlock()
        if running { stop() }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let running = process.isRunning
        lock.unlock()
        if running { stop() }
    }

    /// Called from the process termination handler on normal exit, so an
    /// armed timeout timer is canceled instead of firing later for no reason.
    func didFinish() { markFinished() }

    private func markFinished() {
        lock.lock()
        finished = true
        let work = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        work?.cancel()
    }

    private func stop() {
        // Foundation places each spawned Process in its own new process group
        // (pgid == its own pid), so signaling the negative pid reaches the
        // whole subtree — e.g. `sh -c "…; sleep 30"`, where the long-running
        // work is a grandchild that would otherwise keep the pipes (and this
        // controller's grace period) open indefinitely after only the direct
        // child died. `process.terminate()` only signals the direct child, so
        // this uses `kill(-pid, …)` for both the graceful and forced steps.
        // If the child is somehow not a group leader, fall back to signaling
        // it directly. The forced step is sent to the group even when the
        // direct child already exited, since a surviving grandchild would
        // still hold the pipes open.
        let pid = process.processIdentifier
        if Darwin.kill(-pid, SIGTERM) != 0 { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
            if Darwin.kill(-pid, SIGKILL) != 0, let process, process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
        markFinished()
    }
}
