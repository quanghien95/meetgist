// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import AVFoundation
import UniformTypeIdentifiers
@testable import MeetGistKit
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

    @Test(arguments: [false, true])
    func importWithOfflineAutoTranscribeRunsInsteadOfSticking(video: Bool) async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(prepareRuntimes: Self.fakeReadyQwen3ASR)
        defer { cleanup() }
        #expect(state.qwenASRRuntime.state == .ready)
        state.transcriptionProviderID = ProviderCatalog.offlineQwen3ASRID
        state.autoTranscribe = true
        state.autoGenerateNotes = false

        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await MediaImportFixture.video(in: root)
        // Exercise both audio-only imports and actual video imports.
        let audio = video ? media : root.appendingPathComponent("tone.m4a")

        state.importMedia(from: audio)
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

    private func mediaRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetgist-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: ["mp4", "mov"])
    func videoImportStoresOnlyPlayableAudio(ext: String) async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        state.autoTranscribe = false
        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await MediaImportFixture.video(in: root, extension: ext)
        let original = try Data(contentsOf: video)
        let source = AVURLAsset(url: video)
        #expect(try await source.loadTracks(withMediaType: .video).count == 1)
        #expect(try await source.loadTracks(withMediaType: .audio).count == 1)

        state.importMedia(from: video)
        try await AppStateTestSupport.waitUntil { state.state != .processing && state.selectedMeeting != nil }
        #expect(state.state == .idle)
        #expect(state.lastError == nil)
        let meeting = try #require(state.selectedMeeting)
        #expect(meeting.title == "meeting")
        let names = try FileManager.default.contentsOfDirectory(atPath: meeting.dir.path)
        #expect(Set(names) == Set(["mic.m4a", MeetingStore.titleFile]))
        #expect(try Data(contentsOf: video) == original)
        let audioURL = meeting.dir.appendingPathComponent("mic.m4a")
        let audioAsset = AVURLAsset(url: audioURL)
        #expect(try await audioAsset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await audioAsset.loadTracks(withMediaType: .audio).count == 1)
        let duration = try await audioAsset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)
        // Decode a real sample, proving the result has sound and is playable.
        let file = try AVAudioFile(forReading: audioURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0..<Int(buffer.frameLength)).contains { abs(samples[$0]) > 0.05 })
    }

    @Test func silentVideoFailsWithoutLeavingMeetingOrChangingSource() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await MediaImportFixture.video(in: root, withAudio: false)
        let original = try Data(contentsOf: video)
        state.importMedia(from: video)
        let task = try #require(state.processTask)
        await task.value
        #expect(state.state == .error)
        #expect(state.lastError == AudioTools.ImportError.noAudioTrack.errorDescription)
        #expect(MeetingStore.list(in: state.outputDir).isEmpty)
        #expect(try Data(contentsOf: video) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: state.outputDir.path)
        #expect(!names.contains { $0.hasPrefix("imported-") })
    }

    @Test func invalidMediaCleansUpPartialMeeting() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("broken.mp4")
        try Data("invalid video".utf8).write(to: media)
        state.importMedia(from: media)
        await state.processTask?.value
        #expect(state.state == .error)
        #expect(state.lastError != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: state.outputDir.path)
        #expect(!names.contains { $0.hasPrefix("imported-") })
    }

    @Test func cancelImportAndNewRecordingCannotBeOverwrittenByOldTask() async throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await MediaImportFixture.video(in: root)
        state.importMedia(from: video)
        let task = try #require(state.processTask)
        state.cancelProcessing()
        await task.value
        #expect(state.state == .idle)
        #expect(state.status == L.canceledMessage.en)
        #expect(state.lastError == nil)
        #expect(MeetingStore.list(in: state.outputDir).isEmpty)

        state.importMedia(from: video)
        let oldTask = try #require(state.processTask)
        // Simulate recording's generation bump/cancel without requesting OS
        // microphone or screen permissions in an automated test.
        state.nextProcessGeneration()
        oldTask.cancel()
        state.state = .recording
        state.status = "new recording"
        await oldTask.value
        #expect(state.state == .recording)
        #expect(state.status == "new recording")
        #expect(state.lastError == nil)
        #expect(MeetingStore.list(in: state.outputDir).isEmpty)
    }

    @Test func pickerAcceptsAudioAndCommonVideoTypes() {
        for type in [UTType.mp3, .wav, .aiff, .mpeg4Audio, .mpeg4Movie, .quickTimeMovie] {
            #expect(AppState.importableMediaTypes.contains { type.conforms(to: $0) })
        }
        #expect(!AppState.importableMediaTypes.contains { UTType.pdf.conforms(to: $0) })
    }

    @Test(arguments: [false, true])
    func nativeExportCancellationFinishesWithoutHanging(cancelBeforeStart: Bool) async throws {
        let root = try mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await MediaImportFixture.video(in: root)
        let source = AVURLAsset(url: root.appendingPathComponent("tone.m4a"))
        let tracks = try await source.loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let composition = AVMutableComposition()
        let target = try #require(composition.addMutableTrack(withMediaType: .audio,
                                       preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = try await source.load(.duration)
        // Long enough to observe a running native export before cancelling it.
        for i in 0..<120 {
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track,
                                       at: CMTimeMultiply(duration, multiplier: Int32(i)))
        }
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        let output = root.appendingPathComponent("cancelled.m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        let task = Task { try await export.exportAsync() }
        if !cancelBeforeStart {
            try await AppStateTestSupport.waitUntil(timeout: 5) { export.status == .exporting }
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled export should throw CancellationError")
        } catch is CancellationError {
            #expect(export.status != .exporting)
            #expect(export.status != .completed)
        }
        if cancelBeforeStart { #expect(!FileManager.default.fileExists(atPath: output.path)) }
    }
}
