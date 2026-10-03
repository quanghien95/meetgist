// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

/// Pins `LiveASRRuntimeManager`'s config exactly the way `ManagedRuntimeTests`
/// pins the offline engines': revisions/sizes here were re-verified against
/// the HF API on 2026-09-27 (see the doc comment on
/// `LiveASRRuntimeManager.swift`) — a change to either must be deliberate.
@MainActor
@Suite struct LiveASRRuntimeTests {
    @Test func defaultConfigPinsThe4BitModelForLatency() {
        let c = LiveASRRuntimeManager.qwen0_6BConfig
        #expect(c.rootPath == "MeetGist/LiveASR/Qwen3-ASR-0.6B/v1")
        #expect(c.lockResource == "offline-requirements-qwen")
        #expect(c.modelRepo == "mlx-community/Qwen3-ASR-0.6B-4bit")
        #expect(c.modelRevision == "313d850181767edf09f00a9c289becca70e58cd0")
        #expect(c.modelDownloadBytes == 712_781_279)
        #expect(c.modelReadyFile == "config.json")
    }

    @Test func alternate8BitConfigIsFullyPinnedButNotUsedByDefault() {
        let c = LiveASRRuntimeManager.qwen0_6B8BitConfig
        #expect(c.modelRepo == "mlx-community/Qwen3-ASR-0.6B-8bit")
        #expect(c.modelRevision == "89e96d92ba34aca20b3e29fb10cc284097d1219f")
        #expect(c.modelDownloadBytes == 1_010_773_761)
        // A distinct root from the 4bit default, so switching pins (P4)
        // never reuses a mismatched model directory.
        #expect(c.rootPath != LiveASRRuntimeManager.qwen0_6BConfig.rootPath)
    }

    @Test func rootIsSeparateFromTheOneShotOfflineQwenEngine() {
        #expect(LiveASRRuntimeManager.qwen0_6BConfig.rootPath != Qwen3ASRRuntimeManager.qwen3ASRConfig.rootPath)
        #expect(LiveASRRuntimeManager.qwen0_6BConfig.modelRepo != Qwen3ASRRuntimeManager.qwen3ASRConfig.modelRepo)
        // Both reuse the same pinned mlx-audio requirements lockfile.
        #expect(LiveASRRuntimeManager.qwen0_6BConfig.lockResource == Qwen3ASRRuntimeManager.qwen3ASRConfig.lockResource)
    }

    @Test func revisionIsAFullHexCommitAndTheLockfileIsBundled() {
        for c in [LiveASRRuntimeManager.qwen0_6BConfig, LiveASRRuntimeManager.qwen0_6B8BitConfig] {
            #expect(c.modelRevision.count == 40 && c.modelRevision.allSatisfy(\.isHexDigit))
            #expect(Bundle.module.url(forResource: c.lockResource, withExtension: "lock") != nil)
        }
    }

    @Test func readinessFollowsTheSameContractAsOtherOfflineRuntimes() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-live-asr-runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let runtime = LiveASRRuntimeManager(root: root)
        #expect(runtime.state == .notInstalled)

        try fm.createDirectory(at: runtime.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: runtime.pythonURL.path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(at: runtime.modelURL, withIntermediateDirectories: true)
        fm.createFile(atPath: runtime.modelURL.appendingPathComponent(runtime.config.modelReadyFile).path, contents: Data())
        runtime.refresh()
        #expect(runtime.state == .notInstalled)   // no ready.json yet

        fm.createFile(atPath: root.appendingPathComponent("ready.json").path, contents: Data("{}".utf8))
        let reloaded = LiveASRRuntimeManager(root: root)
        #expect(reloaded.state == .ready)
        try reloaded.remove()
        #expect(reloaded.state == .notInstalled)
    }
}
