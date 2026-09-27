// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

// These tests spawn real short-lived shell subprocesses and assert on wall
// clock timing (kill/timeout must not hang). Serialized for the same reason
// OfflineJobCoordinatorTests is: keep timing-sensitive process behavior from
// being perturbed by unrelated parallel test load.
@Suite(.serialized) struct ChildProcessTests {
    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }

    /// P0-4 regression: writing more than the ~64KB pipe buffer must not
    /// deadlock a `waitUntilExit()`-before-draining implementation. Captured
    /// output is capped (here, at the default 1 MB) and reported truncated.
    @Test func largeStdoutDoesNotDeadlockAndIsCappedWithTruncationNoted() async throws {
        let result = try await ChildProcess.run(Self.shell("yes | head -c 2000000"))
        #expect(result.status == 0)
        #expect(result.stdout.count == ChildProcess.defaultCapturedBytesLimit)
        #expect(result.stdoutTruncated)
        #expect(!result.timedOut)
    }

    /// A short custom limit truncates and still reports the untruncated
    /// stderr stream correctly (the two streams are capped independently).
    @Test func perStreamCapIsIndependentForStdoutAndStderr() async throws {
        let result = try await ChildProcess.run(
            Self.shell("printf 'err' 1>&2; printf '0123456789'"), capturedBytesLimit: 4)
        #expect(result.status == 0)
        #expect(result.stdout.count == 4)
        #expect(result.stdoutTruncated)
        #expect(String(data: result.stderr, encoding: .utf8) == "err")
        #expect(!result.stderrTruncated)
    }

    /// A hung child with a short timeout is stopped and reported `timedOut`,
    /// well before its own (much longer) sleep would have returned.
    @Test func timeoutKillsHangingChildAndReportsTimedOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ChildProcess.run(Self.shell("sleep 30"), timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    /// A child that ignores SIGTERM is still stopped, via the fallback
    /// SIGKILL after the grace period — bounded well under its own sleep.
    @Test func childIgnoringSIGTERMIsForceStoppedByFallbackSIGKILL() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ChildProcess.run(
            Self.shell("trap '' TERM; sleep 30"), timeout: 0.3)
        #expect(result.timedOut)
        #expect(start.duration(to: clock.now) < .seconds(6))
    }

    /// Cancelling the enclosing Swift Task kills the child promptly instead
    /// of waiting for its own (much longer) sleep to finish.
    @Test func taskCancellationKillsTheChildProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await ChildProcess.run(Self.shell("sleep 30"))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    /// `keepTail` retains the end of the stream (what a failing worker's
    /// last log lines need), not the beginning.
    @Test func keepTailRetainsTheLastBytes() async throws {
        let result = try await ChildProcess.run(
            Self.shell("yes a | head -c 300000; printf 'THE-END'"), capturedBytesLimit: 16, keepTail: true)
        #expect(result.status == 0)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.count == 16)
        #expect(String(decoding: result.stdout, as: UTF8.self).hasSuffix("THE-END"))
    }

    /// A process that fails to launch must throw promptly — the output
    /// drains must not wait forever on pipes no child will ever close.
    @Test func launchFailureThrowsWithoutHanging() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/meetgist-no-such-binary")
        await #expect(throws: (any Error).self) {
            _ = try await ChildProcess.run(process)
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
    }
}
