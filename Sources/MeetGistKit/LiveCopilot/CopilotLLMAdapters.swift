// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The one network call every HTTP `CopilotLLM` adapter makes, injectable so
/// adapters are unit-testable without the network (plan §5.5/§8). Real usage
/// goes through `URLSessionTransport`; tests supply a fake that returns a
/// canned response or throws.
public protocol CopilotHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: CopilotHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

// MARK: - Gemini

struct GeminiCopilotLLM: CopilotLLM {
    let apiKey: String
    let baseURL: String
    let model: String
    var transport: any CopilotHTTPTransport = URLSessionTransport()

    var label: String { "Gemini · \(model)" }
    var providerKind: String { "gemini" }

    private struct GenResponse: Decodable {
        struct Candidate: Decodable {
            struct ContentR: Decodable { struct PartR: Decodable { let text: String? }; let parts: [PartR]? }
            let content: ContentR?
        }
        struct UsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }

    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        var generationConfig: [String: Any] = ["temperature": 0.1, "maxOutputTokens": request.maxOutputTokens]
        if request.jsonSchema != nil { generationConfig["responseMimeType"] = "application/json" }
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": request.user]]]],
            "generationConfig": generationConfig,
        ]
        if !request.system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": request.system]]]
        }

        let http = GeminiHTTP(apiKey: apiKey, base: baseURL)
        var urlRequest = http.authed("/v1beta/models/\(model):generateContent")
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = request.timeout

        let start = Date()
        let (data, response) = try await transport.send(urlRequest)
        try HTTPRetry.ensureOK(response, data)
        let decoded = try JSONDecoder().decode(GenResponse.self, from: data)
        let text = decoded.candidates?.first?.content?.parts?.compactMap { $0.text }.joined() ?? ""
        guard !text.isEmpty else { throw PipelineError.badResponse("empty Gemini output") }
        return CopilotLLMResponse(
            text: text,
            inputTokens: decoded.usageMetadata?.promptTokenCount,
            outputTokens: decoded.usageMetadata?.candidatesTokenCount,
            latency: Date().timeIntervalSince(start),
            providerLabel: label)
    }
}

// MARK: - OpenAI-compatible chat

/// Tracks, per (baseURL, model), whether `response_format: json_object` is
/// still believed supported. Some OpenAI-compatible providers 400 on an
/// unrecognized `response_format` — plan §5.5 says fall back to no
/// `response_format` "once per session", so this is process-lifetime, not
/// per-request.
actor ChatJSONModeState {
    static let shared = ChatJSONModeState()
    private var disabledKeys: Set<String> = []
    func isEnabled(for key: String) -> Bool { !disabledKeys.contains(key) }
    func disable(for key: String) { disabledKeys.insert(key) }
    /// Test-only: clears learned state so suites don't leak between tests
    /// that reuse the same base URL/model.
    func resetForTesting() { disabledKeys.removeAll() }
}

struct ChatCopilotLLM: CopilotLLM {
    let apiKey: String
    let baseURL: String
    let model: String
    var transport: any CopilotHTTPTransport = URLSessionTransport()
    var jsonModeState: ChatJSONModeState = .shared

    var label: String { model }
    var providerKind: String { "chat" }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg? }
        struct Usage: Decodable { let promptTokens: Int?; let completionTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens", completionTokens = "completion_tokens" }
        }
        let choices: [Choice]?
        let usage: Usage?
    }

    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        let key = "\(baseURL)|\(model)"
        let wantsJSON = request.jsonSchema != nil
        let start = Date()
        if wantsJSON, await jsonModeState.isEnabled(for: key) {
            do {
                return try await send(request, jsonMode: true, start: start)
            } catch PipelineError.http(400, _) {
                await jsonModeState.disable(for: key)
            }
        }
        return try await send(request, jsonMode: false, start: start)
    }

    private func send(_ request: CopilotLLMRequest, jsonMode: Bool, start: Date) async throws -> CopilotLLMResponse {
        var urlRequest = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = request.timeout
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "max_tokens": request.maxOutputTokens,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(urlRequest)
        try HTTPRetry.ensureOK(response, data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.choices?.first?.message?.content ?? ""
        guard !text.isEmpty else { throw PipelineError.badResponse("empty chat output") }
        return CopilotLLMResponse(
            text: text,
            inputTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens,
            latency: Date().timeIntervalSince(start),
            providerLabel: label)
    }
}

// MARK: - Codex CLI

/// Generalized Codex CLI invocation for Live Copilot — deliberately separate
/// from `CodexCLINotes.swift`'s private `CodexCLIProcessGenerator`, which
/// keeps its exact hardcoded arguments and 120s timeout for the notes path
/// unchanged (`CodexCLINotesTests` must keep passing untouched). This one
/// accepts a caller-supplied timeout and an optional JSON schema file, and
/// always runs with `currentDirectoryURL` set to an empty private temp
/// directory so Codex never sees the user's real project files (plan §5.5,
/// §6).
protocol CodexCLIGeneralGenerating: Sendable {
    func generate(prompt: String, reasoningEffort: String, timeout: TimeInterval,
                  outputSchema: String?) async throws -> String
}

struct CodexCLIGeneralProcessGenerator: CodexCLIGeneralGenerating {
    /// F4 (2026-09-27) measurement on the dev machine, real `codex exec`
    /// calls: a trivial "hi" prompt still took ~6.5-6.9s, and `--json`
    /// events showed ~20,000 input tokens on *every* call before this
    /// account's own content — Codex CLI loads the user's full
    /// `~/.codex/config.toml` (plugins, MCP servers, memories/personality
    /// features) into context on every invocation, none of which the live
    /// semantic call needs. `--ignore-user-config` skips that load and
    /// measurably cuts latency (~20%, ~6.5-8.3s → ~5.0-5.5s over repeated
    /// real calls — see docs/live-copilot-plan.md P4-fix), but it also
    /// drops the user's configured default model in favor of a different
    /// built-in fallback model — on this account that fallback rejects
    /// `model_reasoning_effort=none`, which every semantic call forces
    /// (plan §3). So this optimization only fires when the user's actual
    /// configured model can be read back and pinned explicitly with `-m`;
    /// otherwise behavior is unchanged (original arguments, no
    /// `--ignore-user-config`). `codex exec resume` (reusing a server-side
    /// thread) was also measured and rejected: token usage — and therefore
    /// latency — grows every turn as the whole conversation accumulates,
    /// the opposite of what a bounded-context live path needs.
    ///
    /// Never applied to `CodexCLINotes.swift`'s own process generator (a
    /// separate, unchanged type) — this file is Live Copilot-only.
    static func codexUserConfiguredModel() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eqIndex = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    func generate(prompt: String, reasoningEffort: String, timeout: TimeInterval,
                  outputSchema: String?) async throws -> String {
        guard let codexURL = CodexCLIAvailability.executableURL else {
            throw PipelineError.unsupported("Codex CLI unavailable. Install it and run `codex login` first.")
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("meetgist-live-codex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let promptURL = workDir.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

        var schemaPath: String?
        if let outputSchema {
            let schemaURL = workDir.appendingPathComponent("schema.json")
            try outputSchema.write(to: schemaURL, atomically: true, encoding: .utf8)
            schemaPath = schemaURL.path
        }

        func arguments(fastPath: Bool, outputPath: String) -> [String] {
            var args = ["exec"]
            if fastPath, let model = Self.codexUserConfiguredModel() {
                args += ["--ignore-user-config", "-m", model]
            }
            args += ["--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                     "-c", "model_reasoning_effort=\(reasoningEffort)"]
            if let schemaPath { args += ["--output-schema", schemaPath] }
            args += ["--output-last-message", outputPath, "-"]
            return args
        }

        func runOnce(fastPath: Bool, timeout: TimeInterval) async throws -> String {
            let outputURL = workDir.appendingPathComponent(fastPath ? "result-fast.txt" : "result.txt")
            let inputHandle = try FileHandle(forReadingFrom: promptURL)
            defer { try? inputHandle.close() }

            let process = Process()
            process.executableURL = codexURL
            process.arguments = arguments(fastPath: fastPath, outputPath: outputURL.path)
            // Codex must never see the user's real project files for a Live
            // Assist call — an empty private temp dir, not the meeting/session
            // directory and not the user's cwd.
            process.currentDirectoryURL = workDir
            process.standardInput = inputHandle

            let result = try await ChildProcess.run(process, timeout: timeout, keepTail: true)
            if result.timedOut {
                throw PipelineError.badResponse("Codex CLI did not respond within \(Int(timeout))s and was stopped.")
            }
            guard result.status == 0 else {
                let combined = String(decoding: result.stdout, as: UTF8.self) + String(decoding: result.stderr, as: UTF8.self)
                let tail = combined.split(separator: "\n").suffix(12).joined(separator: "\n")
                throw PipelineError.badResponse(tail.isEmpty ? "Codex CLI exited with status \(result.status)" : tail)
            }
            guard fm.fileExists(atPath: outputURL.path),
                  let output = try? String(contentsOf: outputURL, encoding: .utf8),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineError.badResponse("Codex CLI did not produce a response")
            }
            return output
        }

        let startedAt = Date()
        do {
            return try await runOnce(fastPath: true, timeout: timeout)
        } catch {
            // The fast path only differs by flags that skip the user's own
            // config — if it fails for any reason (an unrecognized model on
            // this account, a config shape this heuristic didn't expect,
            // etc.), fall back once to the original, always-safe invocation
            // with whatever timeout budget remains, rather than surfacing a
            // failure the unmodified code path would not have had.
            guard Self.codexUserConfiguredModel() != nil else { throw error }
            let remaining = timeout - Date().timeIntervalSince(startedAt)
            guard remaining > 1 else { throw error }
            return try await runOnce(fastPath: false, timeout: remaining)
        }
    }
}

struct CodexCLICopilotLLM: CopilotLLM {
    /// Same valid-effort set/normalization as `CodexCLINotesWriter` (kept in
    /// sync deliberately — both are "what Codex CLI accepts").
    private static let validEfforts: Set<String> = ["none", "low", "medium", "high", "xhigh", "max"]
    private static func normalize(_ value: String?) -> String {
        guard let value, validEfforts.contains(value) else { return "none" }
        return value
    }

    let reasoningEffort: String
    var generator: any CodexCLIGeneralGenerating = CodexCLIGeneralProcessGenerator()

    init(reasoningEffort: String?, generator: any CodexCLIGeneralGenerating = CodexCLIGeneralProcessGenerator()) {
        self.reasoningEffort = Self.normalize(reasoningEffort)
        self.generator = generator
    }

    var label: String { "Codex CLI · gpt-6-luna" }
    var providerKind: String { "codex-cli" }

    /// Latency-first decision (2026-09-27, plan §3/§7): **every** Live
    /// Copilot Codex call — the per-turn semantic pass and both V2 flows
    /// (Suggest Answer, Ask Meet Gist) — runs at reasoning effort "none"
    /// regardless of the configured notes reasoning effort, not just
    /// `.semantic`. Plan §7's scheduling section explicitly carries this
    /// forward to V2 ("reasoning effort 'none' unless measurements show
    /// 'low' is needed for acceptable answers — measure before changing");
    /// P6's real measurements (docs/live-copilot-plan.md §13) spot-checked
    /// V2 answer quality at "none" and found it acceptable (short, sayable,
    /// assumptions correctly flagged), so "low" was not adopted. Revisit
    /// per-purpose here (not by changing this file's contract) if a later
    /// measurement shows otherwise.
    private static func reasoningEffort(for purpose: CopilotPurpose, configured: String) -> String { "none" }

    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse {
        let prompt = request.system.isEmpty ? request.user : request.system + "\n\n" + request.user
        let start = Date()
        let effort = Self.reasoningEffort(for: request.purpose, configured: reasoningEffort)
        let text = try await generator.generate(
            prompt: prompt, reasoningEffort: effort,
            timeout: request.timeout, outputSchema: request.jsonSchema)
        try Task.checkCancellation()
        // Codex exposes no token usage.
        return CopilotLLMResponse(text: text, inputTokens: nil, outputTokens: nil,
                                  latency: Date().timeIntervalSince(start), providerLabel: label)
    }
}
