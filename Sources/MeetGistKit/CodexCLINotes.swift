// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// Notes provider backed by a local `codex` CLI subprocess (`codex exec`),
/// authenticated via the user's own ChatGPT subscription login (`codex login`).
/// This is a cloud provider like Gemini/OpenAI/DeepSeek — the transcript leaves
/// the machine over the user's Codex/ChatGPT session — it is not a "local"
/// provider and must never be treated as one. It requires no API key: the
/// prerequisite is that `codex` is installed and already logged in.
protocol CodexCLIGenerating: Sendable {
    func generate(prompt: String, reasoningEffort: String) async throws -> String
}

struct CodexCLINotesWriter: NotesWriter {
    let template: String?
    let language: String
    let reasoningEffort: String
    private let generator: any CodexCLIGenerating
    var label: String { "Codex CLI · gpt-6-luna" }

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage,
         reasoningEffort: String? = nil) {
        self.template = template
        self.language = language
        self.reasoningEffort = Self.normalize(reasoningEffort)
        self.generator = CodexCLIProcessGenerator()
    }

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage,
         reasoningEffort: String? = nil, generator: any CodexCLIGenerating) {
        self.template = template
        self.language = language
        self.reasoningEffort = Self.normalize(reasoningEffort)
        self.generator = generator
    }

    /// Benchmarked on real polished+summary transcripts: none/low/medium give
    /// identical factual content for this extraction-style task, only "medium"
    /// and above spend extra (non-beneficial) reasoning tokens. Falls back to a
    /// safe default if the stored value is empty or not one Codex accepts.
    private static let validEfforts: Set<String> = ["none", "low", "medium", "high", "xhigh", "max"]
    private static func normalize(_ value: String?) -> String {
        guard let value, validEfforts.contains(value) else { return "none" }
        return value
    }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("transcript.md is empty")
        }
        progress("Writing minutes & summary with Codex CLI…")
        let isTemplate = template?.isEmpty == false
        let instructions = isTemplate
            ? Prompts.templatedNotes(template!, language: language)
            : Prompts.polished(language: language)
        let prompt = instructions + "\n\nTRANSCRIPT:\n" + transcript
        let raw = try await generator.generate(prompt: prompt, reasoningEffort: reasoningEffort)
        try Task.checkCancellation()
        if isTemplate {
            let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                throw PipelineError.badResponse("empty Codex CLI output")
            }
            return (output, output)
        }
        let (polished, summary) = splitPolished(raw)
        guard !polished.isEmpty, !summary.isEmpty else {
            throw PipelineError.badResponse("incomplete Codex CLI Meeting Minutes output")
        }
        return (polished, summary)
    }
}

private struct CodexCLIProcessGenerator: CodexCLIGenerating {
    /// Real-world benchmarking showed `codex exec` can hang indefinitely with
    /// no error and no progress for reasons not yet understood (observed even
    /// on previously-successful inputs after repeated calls). Never let this
    /// block Generate/Regenerate forever; time out and surface a clear error.
    static let timeoutSeconds: TimeInterval = 120

    func generate(prompt: String, reasoningEffort: String) async throws -> String {
        guard let codexURL = Self.resolveCodexExecutable() else {
            throw PipelineError.unsupported(
                "Codex CLI was not found. Install it and run `codex login` first."
            )
        }

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("meetgist-codex-notes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("result.md")
        let promptURL = temporary.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        let inputHandle = try FileHandle(forReadingFrom: promptURL)
        defer { try? inputHandle.close() }
        let logURL = temporary.appendingPathComponent("codex.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = codexURL
        process.arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ephemeral",
            "-c", "model_reasoning_effort=\(reasoningEffort)",
            "--output-last-message", outputURL.path,
            "-",
        ]
        process.standardInput = inputHandle
        process.standardOutput = log
        process.standardError = log

        let controller = CodexProcessController(process: process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = {
                    controller.didFinish()
                    continuation.resume(returning: $0.terminationStatus)
                }
                do {
                    try process.run()
                    controller.didStart()
                    controller.armTimeout(seconds: Self.timeoutSeconds)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            controller.cancel()
        }
        try Task.checkCancellation()
        if controller.timedOut {
            throw PipelineError.badResponse(
                "Codex CLI did not respond within \(Int(Self.timeoutSeconds))s and was stopped. " +
                "This can happen with the ChatGPT-subscription auth channel for reasons outside " +
                "MeetGist's control; try again, or pick a different Notes provider."
            )
        }
        guard status == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n").suffix(12).joined(separator: "\n")
            throw PipelineError.badResponse(tail ?? "Codex CLI exited with status \(status)")
        }
        guard fm.fileExists(atPath: outputURL.path),
              let output = try? String(contentsOf: outputURL, encoding: .utf8),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("Codex CLI did not produce a response")
        }
        return output
    }

    /// `codex` is a user-installed CLI, not an app-bundled/pinned runtime (unlike
    /// Local Qwen's isolated MLX runtime) — it must already be installed and
    /// logged in (`codex login`) by the user themselves.
    private static func resolveCodexExecutable() -> URL? { CodexCLIAvailability.executableURL }
}

/// Whether the user's own Codex CLI install is available for the Codex CLI
/// notes provider. Unlike Local Qwen/Offline Whisper, MeetGist does not
/// install, pin, or manage this runtime — it only shells out to whatever the
/// user already has installed and logged in via `codex login`.
public enum CodexCLIAvailability {
    public static var executableURL: URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
    public static var isInstalled: Bool { executableURL != nil }
}

/// Mirrors QwenProcessController: SIGTERM first with a short grace period, then
/// SIGKILL, plus a timer-based timeout since this subprocess can hang with no
/// output at all (no bytes to detect a stall from, unlike a stuck decode loop).
private final class CodexProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var canceled = false
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private(set) var timedOut = false

    init(process: Process) { self.process = process }

    func didStart() {
        lock.lock()
        let shouldCancel = canceled
        lock.unlock()
        if shouldCancel { stop() }
    }

    func armTimeout(seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.fireTimeout() }
        lock.lock()
        if finished { lock.unlock(); return }
        timeoutWorkItem = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fireTimeout() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        timedOut = true
        let running = process.isRunning
        lock.unlock()
        if running { stop() }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let running = process.isRunning
        lock.unlock()
        if running { stop() }
    }

    /// Called from the process termination handler on normal exit, so the
    /// armed timeout timer is canceled instead of firing 120s later for no
    /// reason once the process has already finished.
    func didFinish() { markFinished() }

    private func markFinished() {
        lock.lock()
        finished = true
        let work = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        work?.cancel()
    }

    private func stop() {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
        markFinished()
    }
}
