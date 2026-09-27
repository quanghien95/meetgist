// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MeetGistKit

/// Lets a test drive a fake pipeline/notes-writer's async completion by hand:
/// the fake calls `waitForRelease()` and suspends there; the test calls
/// `waitForEntry()` first to know the fake is actually blocked (not just "about
/// to run"), then `release()` when it wants the fake to complete. Actor-backed
/// so the fakes built on it can be `Sendable`.
actor Gate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    /// Called by the fake: marks entry (waking any `waitForEntry` caller) and
    /// then blocks until `release()`.
    func waitForRelease() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

struct FakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A `MeetingPipeline` double for `AppState.pipelineFactory`. `transcribe`
/// optionally blocks on a `Gate` (to simulate a slow cloud call the test can
/// cancel/supersede mid-flight); `writeNotes` completes immediately, either
/// succeeding or throwing, so tests can exercise the "transcript persisted,
/// notes failed" contract without a real notes provider.
final class FakePipeline: MeetingPipeline, @unchecked Sendable {
    let providerName = "fake-pipeline"
    private let gate: Gate?
    private let transcript: String
    private let notesResult: Result<(String, String), Error>

    init(gate: Gate? = nil, transcript: String, notesResult: Result<(String, String), Error>) {
        self.gate = gate
        self.transcript = transcript
        self.notesResult = notesResult
    }

    func transcribe(sessionDir: URL, micExists: Bool, systemExists: Bool,
                    progress: @escaping @Sendable (String) -> Void) async throws
        -> (transcript: String, transcriberLabel: String) {
        if let gate { await gate.waitForRelease() }
        return (transcript, "fake-transcriber")
    }

    func writeNotes(transcript: String,
                    progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String, notesLabel: String) {
        switch notesResult {
        case .success(let result): return (result.0, result.1, "fake-notes")
        case .failure(let error): throw error
        }
    }
}

/// A `NotesWriter` double for `AppState.notesWriterFactory`, used by
/// `generateMinutes`. Optionally blocks on a `Gate` the same way `FakePipeline`
/// does, so a superseded `generateMinutes` job can be released after the job
/// that superseded it has already finished.
final class FakeNotesWriter: NotesWriter, @unchecked Sendable {
    let label: String
    private let gate: Gate?
    private let result: Result<(String, String), Error>

    init(label: String, gate: Gate? = nil, result: Result<(String, String), Error>) {
        self.label = label
        self.gate = gate
        self.result = result
    }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        if let gate { await gate.waitForRelease() }
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}
