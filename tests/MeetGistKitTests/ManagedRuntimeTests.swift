// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import CryptoKit
@testable import MeetGistKit

/// The offline engines' runtimes share one implementation driven by a config.
/// These pin every config value to what the separate managers used before the
/// merge (so existing installs stay ready and reinstalls fetch the same bits),
/// and exercise the shared setup steps without the network.
@MainActor
@Suite struct ManagedRuntimeTests {
    @Test func whisperConfigIsUnchanged() {
        let c = OfflineRuntimeManager.whisperConfig
        #expect(c.rootPath == "MeetGist/OfflineWhisper/v1")
        #expect(c.lockResource == "offline-requirements")
        #expect(c.modelRepo == "mlx-community/whisper-large-v3-mlx")
        #expect(c.modelRevision == "49e6aa286ad60c14352c404340ded53710378a11")
        #expect(c.modelReadyFile == "weights.npz")
        #expect(c.packageVersion == "0.4.3" && c.mlxVersion == "0.32.1")
        #expect(ManagedOfflineRuntime.marker(for: c) == [
            "python": "3.11.16", "python_build": "20260814", "mlx_whisper": "0.4.3",
            "mlx": "0.32.1", "model": "mlx-community/whisper-large-v3-mlx",
            "model_revision": "49e6aa286ad60c14352c404340ded53710378a11",
        ])
    }

    @Test func qwen3ASRConfigIsUnchanged() {
        let c = Qwen3ASRRuntimeManager.qwen3ASRConfig
        #expect(c.rootPath == "MeetGist/Qwen3ASR/v1")
        #expect(c.lockResource == "offline-requirements-qwen")
        #expect(c.modelRepo == "mlx-community/Qwen3-ASR-1.7B-4bit")
        #expect(c.modelRevision == "78a389c776a5483b2d0d4ea5494e11012e0d6159")
        #expect(c.modelReadyFile == "config.json")
        #expect(ManagedOfflineRuntime.marker(for: c)["mlx_audio"] == "0.5.6")
        #expect(ManagedOfflineRuntime.marker(for: c)["mlx"] == "0.32.2")
    }

    @Test func everyRuntimePinsAnExactRevisionAndABundledLockfile() {
        for c in [OfflineRuntimeManager.whisperConfig, Qwen3ASRRuntimeManager.qwen3ASRConfig] {
            #expect(c.modelRevision.count == 40 && c.modelRevision.allSatisfy(\.isHexDigit))
            #expect(Bundle.module.url(forResource: c.lockResource, withExtension: "lock") != nil)
        }
        #expect(LocalNotesRuntimeManager.modelRevision.count == 40)
        #expect(Bundle.module.url(forResource: "qwen-notes-requirements", withExtension: "lock") != nil)
        #expect(LocalNotesRuntimeManager.marker["mlx_lm"] == "0.31.3")
    }

    @Test func readinessRequiresInterpreterModelFileAndMarker() throws {
        for make in [{ OfflineRuntimeManager(root: $0) as ManagedOfflineRuntime },
                     { Qwen3ASRRuntimeManager(root: $0) as ManagedOfflineRuntime }] {
            let root = TestSupport.makeTempDirectoryURL("meetgist-runtime")
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            var runtime = make(root)
            #expect(runtime.state == .notInstalled)

            try fm.createDirectory(at: runtime.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: runtime.pythonURL.path, contents: Data("#!/bin/sh\n".utf8),
                          attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: runtime.modelURL, withIntermediateDirectories: true)
            fm.createFile(atPath: runtime.modelURL.appendingPathComponent(runtime.config.modelReadyFile).path,
                          contents: Data())
            runtime.refresh()
            #expect(runtime.state == .notInstalled)   // no ready.json yet

            // Existing installs wrote ready.json without "model_revision"; any
            // marker counts, so they must stay ready.
            fm.createFile(atPath: root.appendingPathComponent("ready.json").path, contents: Data("{}".utf8))
            runtime = make(root)
            #expect(runtime.state == .ready)
            try runtime.remove()
            #expect(runtime.state == .notInstalled)
            #expect(!fm.fileExists(atPath: root.path))
        }
    }

    @Test func runAppendsToLogAndReportsItsTailOnFailure() async throws {
        let dir = TestSupport.makeTempDirectoryURL("meetgist-run")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("install.log")

        try await ManagedPython.run("/bin/sh", ["-c", "echo first"], logURL: log)
        do {
            try await ManagedPython.run("/bin/sh", ["-c", "echo boom >&2; exit 3"], logURL: log)
            Issue.record("expected failure")
        } catch let error as ManagedPython.SetupError {
            #expect(error.message.contains("boom"))
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("first") && text.contains("boom"))
    }

    @Test func installCPythonVerifiesHashAndExtracts() async throws {
        let dir = TestSupport.makeTempDirectoryURL("meetgist-cpython")
        let fm = FileManager.default
        let staging = dir.appendingPathComponent("staging")
        try fm.createDirectory(at: staging.appendingPathComponent("python/bin"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        fm.createFile(atPath: staging.appendingPathComponent("python/bin/python3").path,
                      contents: Data("#!/bin/sh\necho fake\n".utf8), attributes: [.posixPermissions: 0o755])
        let archive = dir.appendingPathComponent("fake.tar.gz")
        try await ManagedPython.run("/usr/bin/tar", ["-czf", archive.path, "-C", staging.path, "python"],
                                    logURL: dir.appendingPathComponent("tar.log"))
        let sha = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()

        // A copy per attempt, since installCPython moves the downloaded file.
        @Sendable func fakeDownload(_: URL) async throws -> (URL, URLResponse) {
            let copy = dir.appendingPathComponent("dl-\(UUID().uuidString).tar.gz")
            try FileManager.default.copyItem(at: archive, to: copy)
            return (copy, URLResponse(url: copy, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        let bad = dir.appendingPathComponent("root-bad")
        try ManagedPython.resetRoot(bad)
        await #expect(throws: ManagedPython.SetupError.self) {
            try await ManagedPython.installCPython(into: bad, expectedSHA256: String(repeating: "0", count: 64),
                                                  download: fakeDownload)
        }
        #expect(!fm.fileExists(atPath: ManagedPython.pythonURL(in: bad).path))

        let good = dir.appendingPathComponent("root-good")
        try ManagedPython.resetRoot(good)
        try await ManagedPython.installCPython(into: good, expectedSHA256: sha, download: fakeDownload)
        #expect(fm.isExecutableFile(atPath: ManagedPython.pythonURL(in: good).path))
        #expect(!fm.fileExists(atPath: good.appendingPathComponent("python.tar.gz").path))
    }

    /// Real download of the pinned CPython (~20 MB). Opt-in:
    /// `MEETGIST_NETWORK_TESTS=1 make test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETGIST_NETWORK_TESTS"] == "1"))
    func realPinnedCPythonDownloadMatchesItsHash() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cpython-real")
        defer { try? FileManager.default.removeItem(at: root) }
        try ManagedPython.resetRoot(root)
        try await ManagedPython.installCPython(into: root)
        let out = root.appendingPathComponent("version.log")
        try await ManagedPython.run(ManagedPython.pythonURL(in: root).path, ["--version"], logURL: out)
        #expect(try String(contentsOf: out, encoding: .utf8).contains("3.11.16"))
    }
}
