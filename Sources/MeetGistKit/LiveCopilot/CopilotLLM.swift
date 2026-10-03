// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What a `CopilotLLM` call is for — lets an adapter/engine pick a timeout,
/// token budget, or (later, V2) a different prompt shape without a separate
/// protocol per use. Only `.semantic` is issued by P1/P2; `.suggestAnswer`
/// and `.ask` are reserved for V2 (plan §7, implemented in a later phase).
public enum CopilotPurpose: String, Sendable, Equatable {
    case semantic
    case suggestAnswer
    case ask
}

public struct CopilotLLMRequest: Sendable {
    public var system: String
    public var user: String
    /// JSON Schema text (see `LiveCopilotPrompts.semanticJSONSchema`). `nil`
    /// means free text; when set, JSON-capable adapters request structured
    /// output instead of relying on prompt instructions alone.
    public var jsonSchema: String?
    public var maxOutputTokens: Int
    public var timeout: TimeInterval
    public var purpose: CopilotPurpose

    public init(system: String, user: String, jsonSchema: String? = nil,
                maxOutputTokens: Int, timeout: TimeInterval, purpose: CopilotPurpose) {
        self.system = system
        self.user = user
        self.jsonSchema = jsonSchema
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
        self.purpose = purpose
    }
}

public struct CopilotLLMResponse: Sendable {
    public let text: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latency: TimeInterval
    /// e.g. "Gemini · gemini-flash-latest", "Codex CLI" — provider + model
    /// for metrics/UI, never the prompt or key.
    public let providerLabel: String

    public init(text: String, inputTokens: Int?, outputTokens: Int?, latency: TimeInterval, providerLabel: String) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
        self.providerLabel = providerLabel
    }
}

/// One cloud LLM call, provider-agnostic. Every conformer must never log
/// `request`/`response` content anywhere outside the session's own `live/`
/// folder (plan §5.5/§6). `LiveCopilotEngine` owns retry/timeout/circuit-
/// breaker policy — conformers just make the one call they're given and
/// either return a response or throw.
public protocol CopilotLLM: Sendable {
    var label: String { get }
    /// "gemini" | "chat" | "codex-cli" — used to pick per-provider timeouts
    /// (Codex CLI process start + auth is much slower than an HTTP call).
    var providerKind: String { get }
    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse
}

public enum CopilotLLMs {
    /// Builds the adapter for `provider`'s notes style. There is deliberately
    /// no Claude/Anthropic provider (plan §3) — only `.gemini`, `.chat`
    /// (OpenAI-compatible), and `.codexCLI` are supported; on-device styles
    /// throw a clear, user-facing message since Live Assist requires a cloud
    /// provider by design (plan §5.5).
    public static func make(provider: Provider, key: String?) throws -> any CopilotLLM {
        switch provider.notesStyle {
        case .gemini:
            guard let key, !key.isEmpty else { throw PipelineError.missingKey(provider.name) }
            return GeminiCopilotLLM(apiKey: key, baseURL: provider.baseURL,
                                    model: provider.notesModel ?? "gemini-flash-latest")
        case .chat:
            guard let key, !key.isEmpty else { throw PipelineError.missingKey(provider.name) }
            guard let model = provider.notesModel, !model.isEmpty else {
                throw PipelineError.unsupported("\(provider.name) needs a model name in Settings.")
            }
            return ChatCopilotLLM(apiKey: key, baseURL: provider.baseURL, model: model)
        case .codexCLI:
            return CodexCLICopilotLLM(reasoningEffort: provider.notesReasoningEffort)
        case .apple, .qwenMLX, nil:
            throw PipelineError.unsupported(
                "Live Assist needs a cloud provider — pick Gemini, an OpenAI-compatible provider, " +
                "or Codex CLI in Settings. On-device providers can't be used for Live Assist."
            )
        }
    }
}
