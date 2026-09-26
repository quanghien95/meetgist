// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MeetGistKit
@testable import MeetGistApp

/// Shared helpers for the MeetGistAppTests suites. Every test builds an
/// `AppState` that is fully isolated from the real machine via the
/// constructor injection points on `AppState.init`: a unique, empty
/// `UserDefaults` suite (removed by the returned cleanup), a fresh temp
/// output directory (never `~/Documents/meetgist`), and temp roots for the
/// three local-runtime managers (never Application Support). Construction
/// only reads state from these managers (`refresh()`), so even without the
/// temp roots nothing would be installed/removed — but injecting them keeps
/// tests from depending on whatever happens to be installed on the machine
/// they run on.
@MainActor
enum AppStateTestSupport {
    enum TestSetupError: Error { case couldNotCreateUserDefaultsSuite, timedOut }

    /// - Parameter keyLookup: stands in for `Keychain.get`; defaults to "no
    ///   provider has a key" so callers that don't care about key state get a
    ///   deterministic, harmless default.
    static func makeAppState(keyLookup: @escaping (String) -> String? = { _ in nil })
        throws -> (state: AppState, cleanup: () -> Void) {
        let suiteName = "meetgist-apptests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw TestSetupError.couldNotCreateUserDefaultsSuite
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-appstate-tests-\(UUID().uuidString)")
        let outputDir = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let state = AppState(
            userDefaults: suite,
            initialOutputDir: outputDir,
            keyLookup: keyLookup,
            offlineRuntime: OfflineRuntimeManager(root: root.appendingPathComponent("OfflineWhisper")),
            qwenASRRuntime: Qwen3ASRRuntimeManager(root: root.appendingPathComponent("Qwen3ASR")),
            localNotesRuntime: LocalNotesRuntimeManager(root: root.appendingPathComponent("LocalNotes"))
        )
        let cleanup = {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return (state, cleanup)
    }

    /// A meeting session directory with a stub non-empty `mic.m4a` (so
    /// `AudioTools.isNonEmpty`/`MeetingProcessor.process` accept it as a real
    /// session) and, optionally, a pre-existing `transcript.md` for
    /// notes-only flows (`generateMinutes`).
    @discardableResult
    static func makeMeetingDir(in outputDir: URL, name: String, transcript: String? = nil) throws -> URL {
        let dir = outputDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("mic.m4a"))
        if let transcript {
            try (transcript + "\n").write(to: dir.appendingPathComponent("transcript.md"),
                                         atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Polls `condition` until it's true or `timeout` elapses. AppState's
    /// processing tasks complete asynchronously on the main actor, and Swift
    /// Testing has no built-in "wait for a published change" primitive.
    static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TestSetupError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
