// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Testing
import Foundation
@testable import MeetGistKit

/// Covers the resumable-chunk-checkpoint logic added for long cloud
/// transcriptions (`CloudTranscriptionCheckpoint` + `CloudChunkTranscription`)
/// in isolation, with a fake "transcribe chunk" closure — no network, no real
/// audio. `GeminiTranscriber`/`WhisperTranscriber` only wire this logic to a
/// real HTTP call; the resumability itself lives entirely here.
@Suite struct CloudTranscriptionCheckpointTests {
    /// Thread-safe mutable counter/log (mirrors `HTTPRetryTests.Box`), since
    /// `compute` closures are `@Sendable` and Swift Testing runs concurrently.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func update(_ body: (inout T) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(&value)
        }
        var current: T {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private struct Boom: Error {}

    /// A `compute` closure that fails for indices in `failing`, otherwise
    /// returns a deterministic string and records every index it was actually
    /// called for (never a cache hit).
    static func recordingCompute(failing: Set<Int> = [], calls: Box<[Int]>) -> @Sendable (Int) async throws -> String {
        { i in
            calls.update { $0.append(i) }
            if failing.contains(i) { throw Boom() }
            return "chunk-\(i)"
        }
    }

    // MARK: - Resume only calls the API for missing chunks

    @Test func resumeAfterFailureAtChunkKOnlyCallsAPIForMissingChunks() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_test-model_chunk1200")

        // First run fails on chunk index 3 (of 5) — chunks 0..2 are already
        // committed by the time it throws.
        let firstCalls = Box<[Int]>([])
        await #expect(throws: Boom.self) {
            _ = try await CloudChunkTranscription.run(
                checkpoint: checkpoint, track: "window", count: 5, progress: { _ in },
                compute: Self.recordingCompute(failing: [3], calls: firstCalls))
        }
        #expect(firstCalls.current == [0, 1, 2, 3])

        // A resumed run must only call the API for chunks >= 3 (the ones
        // never successfully committed) — chunks 0..2 are reused from disk.
        let secondCalls = Box<[Int]>([])
        let result = try await CloudChunkTranscription.run(
            checkpoint: checkpoint, track: "window", count: 5, progress: { _ in },
            compute: Self.recordingCompute(calls: secondCalls))
        #expect(secondCalls.current == [3, 4])
        #expect(result == ["chunk-0", "chunk-1", "chunk-2", "chunk-3", "chunk-4"])
    }

    @Test func progressReportsHowManyChunksWereReused() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = CloudTranscriptionCheckpoint(sessionDir: root, configID: "whisper_test-model_chunk1200")

        let calls = Box<[Int]>([])
        await #expect(throws: Boom.self) {
            _ = try await CloudChunkTranscription.run(
                checkpoint: checkpoint, track: "Me", count: 10, progress: { _ in },
                compute: Self.recordingCompute(failing: [7], calls: calls))
        }
        // 7 chunks (0..6) committed before the failure at index 7.
        #expect(calls.current == Array(0..<8))

        let messages = Box<[String]>([])
        _ = try await CloudChunkTranscription.run(
            checkpoint: checkpoint, track: "Me", count: 10,
            progress: { msg in messages.update { $0.append(msg) } },
            compute: Self.recordingCompute(calls: Box<[Int]>([])))
        #expect(messages.current.contains("Reusing 7 of 10 transcribed chunks…"))
    }

    // MARK: - A different config never reuses another config's chunks

    @Test func differentConfigDoesNotReuse() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-config")
        defer { try? FileManager.default.removeItem(at: root) }
        let configA = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_model-a_chunk1200")
        let configB = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_model-b_chunk1200")

        let callsA = Box<[Int]>([])
        _ = try await CloudChunkTranscription.run(
            checkpoint: configA, track: "window", count: 3, progress: { _ in },
            compute: Self.recordingCompute(calls: callsA))
        #expect(callsA.current == [0, 1, 2])

        // Same session, same track/count, but a different model (different
        // configID) — must call the API for every chunk, not reuse configA's.
        let callsB = Box<[Int]>([])
        _ = try await CloudChunkTranscription.run(
            checkpoint: configB, track: "window", count: 3, progress: { _ in },
            compute: Self.recordingCompute(calls: callsB))
        #expect(callsB.current == [0, 1, 2])
    }

    @Test func cloudTranscriptionConfigIDDiffersByStyleModelBaseURLChunkLengthAndOptions() {
        let base = cloudTranscriptionConfigID(style: "gemini", model: "gemini-flash-latest",
                                              baseURL: "https://generativelanguage.googleapis.com",
                                              chunkSeconds: 1200, options: ["mic", "sys"])
        #expect(base != cloudTranscriptionConfigID(style: "whisper", model: "gemini-flash-latest",
                                                   baseURL: "https://generativelanguage.googleapis.com",
                                                   chunkSeconds: 1200, options: ["mic", "sys"]))
        #expect(base != cloudTranscriptionConfigID(style: "gemini", model: "gemini-pro-latest",
                                                   baseURL: "https://generativelanguage.googleapis.com",
                                                   chunkSeconds: 1200, options: ["mic", "sys"]))
        #expect(base != cloudTranscriptionConfigID(style: "gemini", model: "gemini-flash-latest",
                                                   baseURL: "https://custom.example.com",
                                                   chunkSeconds: 1200, options: ["mic", "sys"]))
        #expect(base != cloudTranscriptionConfigID(style: "gemini", model: "gemini-flash-latest",
                                                   baseURL: "https://generativelanguage.googleapis.com",
                                                   chunkSeconds: 600, options: ["mic", "sys"]))
        #expect(base != cloudTranscriptionConfigID(style: "gemini", model: "gemini-flash-latest",
                                                   baseURL: "https://generativelanguage.googleapis.com",
                                                   chunkSeconds: 1200, options: ["mic"]))
    }

    // MARK: - Atomic writes: a partial/leftover `.tmp` is never reused

    @Test func partiallyWrittenTmpFileIsNeverReusedAsACommittedChunk() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-atomic")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_test-model_chunk1200")

        // Simulate a crash mid-write: a `.tmp` sibling exists but the real
        // `window-0000.txt` never got renamed into place.
        try FileManager.default.createDirectory(at: checkpoint.directory, withIntermediateDirectories: true)
        try Data("half-written".utf8).write(to: checkpoint.directory.appendingPathComponent("window-0000.txt.tmp"))

        #expect(checkpoint.load(track: "window", index: 0) == nil)

        let calls = Box<[Int]>([])
        let result = try await CloudChunkTranscription.run(
            checkpoint: checkpoint, track: "window", count: 1, progress: { _ in },
            compute: Self.recordingCompute(calls: calls))
        // The API must be called for chunk 0 — the leftover .tmp is not a
        // committed chunk — and the final committed file must hold the real
        // (non-"half-written") result.
        #expect(calls.current == [0])
        #expect(result == ["chunk-0"])
        #expect(checkpoint.load(track: "window", index: 0) == "chunk-0")
    }

    @Test func saveIsAtomicAndLeavesNoTmpFileBehind() throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-save")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = CloudTranscriptionCheckpoint(sessionDir: root, configID: "whisper_test-model_chunk1200")

        try checkpoint.save("hello", track: "Me", index: 0)

        #expect(checkpoint.load(track: "Me", index: 0) == "hello")
        let tmp = checkpoint.directory.appendingPathComponent("Me-0000.txt.tmp")
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    // MARK: - Cancellation leaves committed chunks intact, never a half-written one

    @Test func cancellationLeavesCommittedChunksIntactAndCommitsNoPartialChunk() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_test-model_chunk1200")

        let started = Box<Int>(0)
        let task = Task {
            try await CloudChunkTranscription.run(
                checkpoint: checkpoint, track: "window", count: 5, progress: { _ in }
            ) { i in
                started.update { $0 += 1 }
                if i == 2 {
                    // Block "in flight" long enough to be cancelled mid-chunk.
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                return "chunk-\(i)"
            }
        }
        // Let chunks 0 and 1 commit, and chunk 2 start, before cancelling.
        while started.current < 3 { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }

        // 0 and 1 committed; 2 was cancelled mid-flight and must not be
        // committed (no result was ever returned to be saved); 3 and 4 were
        // never reached.
        #expect(checkpoint.load(track: "window", index: 0) == "chunk-0")
        #expect(checkpoint.load(track: "window", index: 1) == "chunk-1")
        #expect(checkpoint.load(track: "window", index: 2) == nil)
        #expect(checkpoint.load(track: "window", index: 3) == nil)
        #expect(checkpoint.load(track: "window", index: 4) == nil)
        // No leftover .tmp from the cancelled chunk either.
        let tmp = checkpoint.directory.appendingPathComponent("window-0002.txt.tmp")
        #expect(!FileManager.default.fileExists(atPath: tmp.path))

        // A subsequent, uncancelled run resumes cleanly from chunk 2 onward.
        let calls = Box<[Int]>([])
        let result = try await CloudChunkTranscription.run(
            checkpoint: checkpoint, track: "window", count: 5, progress: { _ in },
            compute: Self.recordingCompute(calls: calls))
        #expect(calls.current == [2, 3, 4])
        #expect(result == ["chunk-0", "chunk-1", "chunk-2", "chunk-3", "chunk-4"])
    }

    // MARK: - Merged output after an interrupted+resumed run matches an uninterrupted one

    @Test func mergedResultAfterInterruptedResumeMatchesUninterruptedRun() async throws {
        let uninterruptedRoot = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-uninterrupted")
        let resumedRoot = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-resumed")
        defer {
            try? FileManager.default.removeItem(at: uninterruptedRoot)
            try? FileManager.default.removeItem(at: resumedRoot)
        }

        let uninterrupted = CloudTranscriptionCheckpoint(sessionDir: uninterruptedRoot, configID: "gemini_m_chunk1200")
        let uninterruptedResult = try await CloudChunkTranscription.run(
            checkpoint: uninterrupted, track: "window", count: 6, progress: { _ in },
            compute: Self.recordingCompute(calls: Box<[Int]>([])))

        let resumed = CloudTranscriptionCheckpoint(sessionDir: resumedRoot, configID: "gemini_m_chunk1200")
        await #expect(throws: Boom.self) {
            _ = try await CloudChunkTranscription.run(
                checkpoint: resumed, track: "window", count: 6, progress: { _ in },
                compute: Self.recordingCompute(failing: [4], calls: Box<[Int]>([])))
        }
        let resumedResult = try await CloudChunkTranscription.run(
            checkpoint: resumed, track: "window", count: 6, progress: { _ in },
            compute: Self.recordingCompute(calls: Box<[Int]>([])))

        #expect(resumedResult == uninterruptedResult)
        #expect(resumedResult.joined(separator: "\n") == uninterruptedResult.joined(separator: "\n"))
    }

    // MARK: - Success cleanup (`MeetingProcessor.process`'s contract)

    @Test func clearAllRemovesEveryConfigsCheckpointsUnderTheSession() async throws {
        let root = TestSupport.makeTempDirectoryURL("meetgist-cloud-checkpoint-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CloudTranscriptionCheckpoint(sessionDir: root, configID: "gemini_a_chunk1200")
        let b = CloudTranscriptionCheckpoint(sessionDir: root, configID: "whisper_b_chunk1200")
        try a.save("x", track: "window", index: 0)
        try b.save("y", track: "Me", index: 0)

        CloudTranscriptionCheckpoint.clearAll(sessionDir: root)

        #expect(a.load(track: "window", index: 0) == nil)
        #expect(b.load(track: "Me", index: 0) == nil)
        #expect(!FileManager.default.fileExists(atPath: a.rootDirectory.path))
    }

    /// The id is used as a directory name, so a very long custom base URL must
    /// still produce a short, filesystem-safe — and still distinct — id.
    @Test func longBaseURLProducesShortDistinctConfigID() {
        let longA = "https://example.com/" + String(repeating: "a", count: 300)
        let longB = "https://example.com/" + String(repeating: "b", count: 300)
        let a = cloudTranscriptionConfigID(style: "whisper", model: "whisper-1", baseURL: longA, chunkSeconds: 1200)
        let b = cloudTranscriptionConfigID(style: "whisper", model: "whisper-1", baseURL: longB, chunkSeconds: 1200)
        #expect(a.utf8.count < 200)
        #expect(a != b)
        #expect(!a.contains("/"))
    }
}
