// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

struct QwenNotesRequest: Codable, Sendable {
    let transcript: String
    let instructions: String
    let isTemplate: Bool
}

struct QwenNotesMetrics: Codable, Sendable {
    let elapsedSeconds: Double
    let modelLoadSeconds: Double?
    let prefillSeconds: Double?
    let generationSeconds: Double?
    let generationTokensPerSecond: Double?
    let peakMemoryGB: Double
    let promptTokens: Int
    let generationTokens: Int
    let sourceChunks: Int
    // Phase 1 baseline instrumentation, kept alongside the original fields
    // above (never removed) so old and new runs stay comparable.
    let wallClockSeconds: Double?
    let numberOfLLMCalls: Int?
    let mapCalls: Int?
    let reduceCalls: Int?
    let finalCalls: Int?
    let usedDirectContext: Bool?

    init(elapsedSeconds: Double, modelLoadSeconds: Double? = nil,
         prefillSeconds: Double? = nil, generationSeconds: Double? = nil,
         generationTokensPerSecond: Double? = nil, peakMemoryGB: Double,
         promptTokens: Int, generationTokens: Int, sourceChunks: Int,
         wallClockSeconds: Double? = nil, numberOfLLMCalls: Int? = nil,
         mapCalls: Int? = nil, reduceCalls: Int? = nil, finalCalls: Int? = nil,
         usedDirectContext: Bool? = nil) {
        self.elapsedSeconds = elapsedSeconds
        self.modelLoadSeconds = modelLoadSeconds
        self.prefillSeconds = prefillSeconds
        self.generationSeconds = generationSeconds
        self.generationTokensPerSecond = generationTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.sourceChunks = sourceChunks
        self.wallClockSeconds = wallClockSeconds
        self.numberOfLLMCalls = numberOfLLMCalls
        self.mapCalls = mapCalls
        self.reduceCalls = reduceCalls
        self.finalCalls = finalCalls
        self.usedDirectContext = usedDirectContext
    }
}

struct QwenNotesResponse: Codable, Sendable {
    let polished: String
    let summary: String
    let metrics: QwenNotesMetrics?
}

protocol QwenMLXGenerating: Sendable {
    func generate(_ request: QwenNotesRequest) async throws -> QwenNotesResponse
}

struct QwenMLXNotesWriter: NotesWriter {
    let template: String?
    let language: String
    private let generator: any QwenMLXGenerating
    var label: String { LocalNotesRuntimeManager.activeModel.displayLabel }

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage) {
        self.template = template
        self.language = language
        self.generator = QwenMLXProcessGenerator()
    }

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage,
         generator: any QwenMLXGenerating) {
        self.template = template
        self.language = language
        self.generator = generator
    }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("transcript.md is empty")
        }
        progress("Loading Qwen3 4B and preparing local Meeting Minutes…")
        let isTemplate = template?.isEmpty == false
        let instructions = isTemplate
            ? Prompts.templatedNotes(template!, language: language)
            : Prompts.polished(language: language)
        let response = try await generator.generate(QwenNotesRequest(
            transcript: transcript,
            instructions: instructions,
            isTemplate: isTemplate
        ))
        try Task.checkCancellation()
        guard !response.polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("incomplete local Qwen Meeting Minutes output")
        }
        return (response.polished, response.summary)
    }
}

private struct QwenMLXProcessGenerator: QwenMLXGenerating {
    let root: URL

    init(root: URL = LocalNotesRuntimeManager.defaultRoot) {
        self.root = root
    }

    func generate(_ request: QwenNotesRequest) async throws -> QwenNotesResponse {
        guard LocalNotesRuntimeManager.isReady(at: root) else {
            throw PipelineError.unsupported(
                "Local Qwen Notes is not installed. Install it in Settings → AI Provider."
            )
        }
        guard let worker = Bundle.module.url(forResource: "qwen_notes_worker",
                                             withExtension: "py") else {
            throw PipelineError.unsupported("The bundled Local Qwen Notes worker is missing.")
        }

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("meetgist-qwen-notes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let requestURL = temporary.appendingPathComponent("request.json")
        let outputURL = temporary.appendingPathComponent("result.json")
        let logURL = temporary.appendingPathComponent("worker.log")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        let config = LocalNotesRuntimeManager.activeModel
        let process = Process()
        process.executableURL = root.appendingPathComponent("python/bin/python3")
        process.arguments = [
            worker.path,
            "--request", requestURL.path,
            "--output", outputURL.path,
            "--model", root.appendingPathComponent("model").path,
            "--direct-source-tokens", String(config.directSourceTokens),
            "--map-source-tokens", String(config.mapSourceTokens),
            "--map-output-tokens", String(config.mapOutputTokens),
            "--reduce-source-tokens", String(config.reduceSourceTokens),
            "--reduce-output-tokens", String(config.reduceOutputTokens),
            "--final-output-tokens", String(config.finalOutputTokens),
            "--temperature", String(config.temperature),
            "--top-p", String(config.topP),
            "--top-k", String(config.topK),
        ]
        var environment = ProcessInfo.processInfo.environment
        // The setup step is the only code allowed to access Hugging Face. Normal
        // generation loads the pinned local directory and is forced offline.
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardOutput = log
        process.standardError = log

        let controller = QwenProcessController(process: process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = {
                    continuation.resume(returning: $0.terminationStatus)
                }
                do {
                    try process.run()
                    controller.didStart()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            controller.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n").suffix(12).joined(separator: "\n")
            throw PipelineError.badResponse(tail ?? "Local Qwen worker exited with status \(status)")
        }
        guard fm.fileExists(atPath: outputURL.path) else {
            throw PipelineError.badResponse("Local Qwen worker did not produce result.json")
        }
        do {
            let response = try JSONDecoder().decode(
                QwenNotesResponse.self, from: Data(contentsOf: outputURL))
            if let metrics = response.metrics,
               let data = try? JSONEncoder().encode(metrics) {
                try? data.write(to: root.appendingPathComponent("last-run-metrics.json"),
                                options: .atomic)
            }
            return response
        } catch {
            throw PipelineError.badResponse("Invalid Local Qwen result JSON: \(error.localizedDescription)")
        }
    }
}

/// Process cancellation must stop MLX before recording starts. SIGTERM gets a
/// short grace period; SIGKILL prevents a stuck native operation from surviving.
private final class QwenProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var canceled = false

    init(process: Process) { self.process = process }

    func didStart() {
        lock.lock()
        let shouldCancel = canceled
        lock.unlock()
        if shouldCancel { stop() }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let running = process.isRunning
        lock.unlock()
        if running { stop() }
    }

    private func stop() {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }
}
