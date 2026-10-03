// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct OfflineJobStoreTests {
    @Test func qwenDecodingRevisionDoesNotReuseOldParts() {
        #expect(offlineConfigID(engine: qwenASREngine, model: qwenASRModel)
                == "qwen3-asr-mlx-community-Qwen3-ASR-1.7B-4bit-v2")
        #expect(offlineConfigID(engine: offlineEngine, model: offlineModel)
                == "mlx-whisper-mlx-community-whisper-large-v3-mlx-v1")
    }

    @Test func legacyEchoConfigStillDecodesWithoutReencodingRemovedField() throws {
        let config = OfflineJobConfig()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["aec"] = "v1"
        let decoded = try JSONDecoder().decode(OfflineJobConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == config)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["aec"] == nil)
    }

    @Test @MainActor func prepareReplacesEchoJobWithoutReusingItsPartsOrChangingTranscript() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-remove-echo-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineJobStore(sessionDir: root)
        try FileManager.default.createDirectory(at: store.partsDir, withIntermediateDirectories: true)
        var legacy = OfflineJobState(jobID: "legacy-echo-job", sessionID: root.lastPathComponent,
                                     config: OfflineJobConfig(), tracks: ["mic": OfflineTrackState(durationSeconds: 30)])
        legacy.configID += "-aecv1"
        try store.save(legacy)
        let part = OfflinePart(schemaVersion: 1, jobID: legacy.jobID, sessionID: legacy.sessionID,
                               configID: legacy.configID, track: "mic", chunkIndex: 0,
                               coreStartSeconds: 0, coreEndSeconds: 30, processingSeconds: 1,
                               segments: [OfflineSegment(startSeconds: 0, endSeconds: 30, text: "old filtered audio")])
        try JSONEncoder().encode(part).write(to: store.partsDir.appendingPathComponent("mic-0000.json"))
        let transcript = root.appendingPathComponent("transcript.md")
        let existingTranscript = Data("existing completed transcript".utf8)
        try existingTranscript.write(to: transcript)

        let coordinator = OfflineJobCoordinator(runtime: OfflineRuntimeManager(root: root.appendingPathComponent("runtime")))
        let fresh = try await coordinator.prepare(sessionDir: root, config: OfflineJobConfig())
        #expect(fresh.jobID != legacy.jobID)
        #expect(fresh.configID == offlineConfigID(engine: offlineEngine, model: offlineModel))
        #expect(!OfflineJobStore.isReusable(part, for: fresh, track: "mic", interval: (index: 0, start: 0, end: 30)))
        #expect(try Data(contentsOf: transcript) == existingTranscript)
    }

    @Test func recoveryRemovesTemporaryAndRebuildsProgressFromValidParts() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineJobStore(sessionDir: root)
        try FileManager.default.createDirectory(at: store.partsDir, withIntermediateDirectories: true)
        var state = OfflineJobState(
            jobID: "offline-test", sessionID: root.lastPathComponent,
            status: .transcribing, config: OfflineJobConfig(),
            tracks: ["system": OfflineTrackState(durationSeconds: 601)])
        try store.save(state)

        let first = OfflinePart(
            schemaVersion: 1, jobID: state.jobID, sessionID: state.sessionID,
            configID: state.configID, track: "system", chunkIndex: 0,
            coreStartSeconds: 0, coreEndSeconds: 300, processingSeconds: 120,
            segments: [])
        let data = try JSONEncoder().encode(first)
        try data.write(to: store.partsDir.appendingPathComponent("system-0000.json"))
        try Data("broken".utf8).write(to: store.partsDir.appendingPathComponent("system-0001.json"))
        let abandoned = store.partsDir.appendingPathComponent("system-0002.json.tmp")
        try Data("partial".utf8).write(to: abandoned)

        state = try store.recover()
        #expect(state.status == .pending)
        #expect(abs(state.progress.processedSeconds - 300) <= 0.001)
        #expect(abs(state.progress.totalSeconds - 601) <= 0.001)
        #expect(abs((state.progress.rollingRTF ?? -1) - 0.4) <= 0.001)
        #expect(state.progress.etaSeconds == 120)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    /// P0-5 regression: `recoveredView()` computes the same recovered progress
    /// as `recover()` but must never touch disk — a scan over sessions that
    /// aren't actually starting/resuming has no business deleting an active
    /// job's tmp files or rewriting its state.json out from under it.
    @Test func recoveredViewComputesSameProgressWithoutTouchingDisk() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-offline-store-readonly")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineJobStore(sessionDir: root)
        try FileManager.default.createDirectory(at: store.partsDir, withIntermediateDirectories: true)
        let state = OfflineJobState(
            jobID: "offline-test", sessionID: root.lastPathComponent,
            status: .transcribing, config: OfflineJobConfig(),
            tracks: ["system": OfflineTrackState(durationSeconds: 601)])
        try store.save(state)

        let part = OfflinePart(
            schemaVersion: 1, jobID: state.jobID, sessionID: state.sessionID,
            configID: state.configID, track: "system", chunkIndex: 0,
            coreStartSeconds: 0, coreEndSeconds: 300, processingSeconds: 120,
            segments: [])
        try JSONEncoder().encode(part).write(to: store.partsDir.appendingPathComponent("system-0000.json"))
        let abandoned = store.partsDir.appendingPathComponent("system-0002.json.tmp")
        try Data("partial".utf8).write(to: abandoned)
        let stateBytesBefore = try Data(contentsOf: store.stateURL)

        let view = try store.recoveredView()
        #expect(view.status == .pending)
        #expect(abs(view.progress.processedSeconds - 300) <= 0.001)
        #expect(abs(view.progress.totalSeconds - 601) <= 0.001)

        // Untouched: the tmp file survives, and state.json is byte-identical
        // to what it was before the read-only view was computed.
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try Data(contentsOf: store.stateURL) == stateBytesBefore)
        // The on-disk status is still what was saved (.transcribing) — only
        // the in-memory view reports .pending.
        #expect(try store.load().status == .transcribing)
    }
}
