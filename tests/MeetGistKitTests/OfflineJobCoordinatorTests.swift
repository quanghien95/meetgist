// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

// These tests spawn real short-lived shell subprocesses and assert on wall
// clock timing (e.g. force-stop must not hang). Serialized to keep the
// process/timing behavior from being perturbed by unrelated parallel test
// load rather than because any state is shared between the tests.
@Suite(.serialized) struct OfflineJobCoordinatorTests {
    @Test @MainActor func workerExitIsConfirmedBeforeRecordingAndPauseResume() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\ntrap 'exit 75' TERM INT\nwhile true; do sleep 1; done\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))

        let session = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let runtime = OfflineRuntimeManager(root: runtimeRoot)
        #expect(runtime.state == .ready)
        let coordinator = OfflineJobCoordinator(runtime: runtime)
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        #expect(coordinator.activeSessionID != nil)
        await coordinator.stopForRecording()
        #expect(coordinator.activeSessionID == nil)
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .pending)

        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        await coordinator.pause()
        #expect(coordinator.activeSessionID == nil)
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .paused)

        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .transcribing)
        await coordinator.cancel()
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .canceled)
    }

    @Test @MainActor func workerThatIgnoresTerminationIsForceStopped() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-force-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\ntrap '' TERM INT\nwhile true; do sleep 1; done\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))
        let session = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: runtimeRoot))
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())

        let clock = ContinuousClock()
        let started = clock.now
        await coordinator.stopForRecording()

        #expect(started.duration(to: clock.now) < .seconds(5))
        #expect(coordinator.activeSessionID == nil)
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .pending)
    }

    @Test @MainActor func confirmedResetDeletesOnlyGeneratedTranscriptionArtifacts() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-reset")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcription = root.appendingPathComponent("transcription/parts")
        try FileManager.default.createDirectory(at: transcription, withIntermediateDirectories: true)
        for name in ["system.m4a", "mic.m4a", "sync_map.json", "transcript.md", "summary.md"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("part".utf8).write(to: transcription.appendingPathComponent("system-0000.json"))

        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: root.appendingPathComponent("runtime")))
        try coordinator.resetTranscription(sessionDir: root)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcription").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))
        for name in ["system.m4a", "mic.m4a", "sync_map.json", "summary.md"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    /// P0-5 regression: `scan()` must not race (or mutate disk for) the
    /// session an active worker is writing to. The active session is
    /// auto-excluded, so its in-memory `.transcribing` status survives a scan
    /// unchanged (a non-excluded read would show `.pending`, since a
    /// read-only recovered view always reports stale `.transcribing` as
    /// `.pending`), and its tmp files/state.json are untouched on disk.
    @Test @MainActor func scanExcludesTheActiveSessionAndLeavesItsDiskStateUntouched() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-scan-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\ntrap 'exit 75' TERM INT\nwhile true; do sleep 1; done\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))

        let outputDir = root.appendingPathComponent("meetings")
        let session = outputDir.appendingPathComponent("active-meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: runtimeRoot))
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())
        #expect(coordinator.activeSessionID == session.lastPathComponent)
        #expect(coordinator.state(for: session.lastPathComponent)?.status == .transcribing)

        let store = OfflineJobStore(sessionDir: session)
        let stateBytesBefore = try Data(contentsOf: store.stateURL)
        let abandoned = store.partsDir.appendingPathComponent("system-0002.json.tmp")
        try Data("partial".utf8).write(to: abandoned)

        coordinator.scan(outputDir: outputDir)
        try await Task.sleep(for: .milliseconds(200))   // scan() hops off-actor; give it time to land.

        #expect(coordinator.state(for: session.lastPathComponent)?.status == .transcribing)
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try Data(contentsOf: store.stateURL) == stateBytesBefore)

        await coordinator.cancel()
    }

    /// P2-5 regression: the worker's stdout/stderr go to a per-meeting log
    /// file (not /dev/null), and a non-zero exit includes the log's tail in
    /// `lastError` instead of just a bare exit code.
    @Test @MainActor func workerCrashIsLoggedAndTailIncludedInLastError() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-worker-log")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("runtime")
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'boom: something went wrong' 1>&2\nexit 7\n"
            .write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: runtimeRoot.appendingPathComponent("model/weights.npz"))
        try Data("{}".utf8).write(to: runtimeRoot.appendingPathComponent("ready.json"))

        let session = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: runtimeRoot))
        try await coordinator.start(sessionDir: session, config: OfflineJobConfig())

        // The monitor loop polls every 400ms; give it a bounded window to
        // observe the (near-instant) worker exit rather than a fixed sleep.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while coordinator.activeSessionID != nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let job = coordinator.state(for: session.lastPathComponent)
        #expect(job?.status == .failed)
        #expect(job?.lastError?.contains("boom: something went wrong") == true)

        let logURL = OfflineJobStore(sessionDir: session).workerLogURL
        #expect(FileManager.default.fileExists(atPath: logURL.path))
        #expect(try String(contentsOf: logURL).contains("boom: something went wrong"))
    }
}
