// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import MeetGistKit
@testable import MeetGistApp

/// Found by the end-to-end run: importing audio with an offline transcription
/// provider and auto-transcribe on left the app stuck in `.processing`, because
/// the import's own `.processing` state tripped processOffline's
/// "another task is running" guard.
@MainActor
@Suite(.serialized) struct AppStateImportTests {
    /// Installs a fake "ready" Qwen3-ASR runtime whose worker marks the job
    /// completed and exits.
    private static func fakeReadyQwen3ASR(_ root: URL) throws {
        let runtime = root.appendingPathComponent("Qwen3ASR")
        let python = runtime.appendingPathComponent("python/bin/python3")
        let fm = FileManager.default
        try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: runtime.appendingPathComponent("model"), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        STATE="$3/transcription/state.json"
        /usr/bin/python3 - "$STATE" <<'PY'
        import json, os, sys
        p = sys.argv[1]
        s = json.load(open(p))
        s["status"] = "completed"
        open(p + ".tmp", "w").write(json.dumps(s))
        os.replace(p + ".tmp", p)
        PY
        exit 0
        """.write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: runtime.appendingPathComponent("model/config.json"))
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("ready.json"))
    }

    @Test func importWithOfflineAutoTranscribeRunsInsteadOfSticking() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(prepareRuntimes: Self.fakeReadyQwen3ASR)
        defer { cleanup() }
        #expect(state.qwenASRRuntime.state == .ready)
        state.transcriptionProviderID = ProviderCatalog.offlineQwen3ASRID
        state.autoTranscribe = true
        state.autoGenerateNotes = false

        // A real, tiny audio file for AudioTools.export.
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-import-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audio) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "hello"]
        try say.run(); say.waitUntilExit()

        state.importAudio(from: audio)
        try await AppStateTestSupport.waitUntil(timeout: 20) {
            state.state != .processing && state.status == L.transcriptReadyMessage.en
        }
        #expect(state.status != L.anotherProcessingRunning.en)
        #expect(state.state == .idle)
        #expect(state.status == L.transcriptReadyMessage.en)
        // Imported meetings are titled after the source file, not the timestamp.
        try await AppStateTestSupport.waitUntil(timeout: 5) { state.selectedMeeting != nil }
        #expect(state.selectedMeeting?.title == audio.deletingPathExtension().lastPathComponent)
    }
}
