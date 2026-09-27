// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// How a transcription provider turns audio into a transcript. The raw value
/// is exactly what's persisted in `Provider` JSON (custom providers, stored in
/// UserDefaults) — do not rename cases without a migration.
public enum TranscribeStyle: String, Codable, Sendable, CaseIterable {
    case gemini, whisper, offline

    /// True if this style calls a cloud API that needs a user-supplied API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini, .whisper: return true
        case .offline: return false
        }
    }

    /// True if this style runs entirely on-device via an app-managed local
    /// worker (never a network call).
    public var isLocal: Bool {
        switch self {
        case .offline: return true
        case .gemini, .whisper: return false
        }
    }
}

/// How a notes provider turns a transcript into minutes + summary. The raw
/// value is exactly what's persisted in `Provider` JSON — do not rename cases
/// without a migration.
public enum NotesStyle: String, Codable, Sendable, CaseIterable {
    case gemini, chat, apple, qwenMLX = "qwen-mlx", codexCLI = "codex-cli"

    /// True if this style calls a cloud API that needs a user-supplied API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini, .chat: return true
        case .apple, .qwenMLX, .codexCLI: return false
        }
    }

    /// True if this style runs entirely on-device. Codex CLI is deliberately
    /// NOT on-device here even though it runs as a local subprocess — it is a
    /// cloud provider via the user's own ChatGPT login (see ARCHITECTURE.md).
    public var isOnDevice: Bool {
        switch self {
        case .apple, .qwenMLX: return true
        case .gemini, .chat, .codexCLI: return false
        }
    }
}

/// A user-selectable AI provider. The pipeline has two slots — a transcription
/// provider (audio → transcript) and a notes provider (transcript → minutes +
/// summary) — so you can mix e.g. Gemini transcription with DeepSeek notes.
/// Everything is bring-your-own-key (stored in Keychain by `keyAccount`).
public struct Provider: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var baseURL: String
    /// `.gemini`, `.whisper` (OpenAI-compatible), `.offline` (bundled worker),
    /// or nil.
    public var transcribeStyle: TranscribeStyle?
    public var transcribeModel: String?
    /// `.gemini`, `.chat` (OpenAI-compatible), `.apple` (Foundation Models),
    /// `.qwenMLX` (app-managed MLX-LM), `.codexCLI` (local Codex CLI
    /// subprocess), or nil.
    public var notesStyle: NotesStyle?
    public var notesModel: String?
    public var keyHelp: String?
    public var isCustom: Bool
    /// Codex CLI only: `-c model_reasoning_effort=<value>` for the notes call —
    /// "none", "low", "medium" (default), "high", "xhigh", or "max".
    public var notesReasoningEffort: String?

    public init(id: String, name: String, baseURL: String,
                transcribeStyle: TranscribeStyle? = nil, transcribeModel: String? = nil,
                notesStyle: NotesStyle? = nil, notesModel: String? = nil,
                keyHelp: String? = nil, isCustom: Bool = false,
                notesReasoningEffort: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.transcribeStyle = transcribeStyle; self.transcribeModel = transcribeModel
        self.notesStyle = notesStyle; self.notesModel = notesModel
        self.keyHelp = keyHelp; self.isCustom = isCustom
        self.notesReasoningEffort = notesReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, transcribeStyle, transcribeModel, notesStyle, notesModel
        case keyHelp, isCustom, notesReasoningEffort
    }

    /// Custom decoding so persistence stays backward-compatible: custom
    /// providers are stored as `[Provider]` JSON in UserDefaults, and an
    /// unknown/removed style string (e.g. from a future or rolled-back build)
    /// must decode to `nil` for that one field rather than throwing and
    /// silently wiping the entire array of a user's custom providers. Every
    /// other field keeps the same required/optional decoding behavior as the
    /// compiler-synthesized initializer this replaces.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        transcribeModel = try c.decodeIfPresent(String.self, forKey: .transcribeModel)
        notesModel = try c.decodeIfPresent(String.self, forKey: .notesModel)
        keyHelp = try c.decodeIfPresent(String.self, forKey: .keyHelp)
        isCustom = try c.decode(Bool.self, forKey: .isCustom)
        notesReasoningEffort = try c.decodeIfPresent(String.self, forKey: .notesReasoningEffort)
        transcribeStyle = (try c.decodeIfPresent(String.self, forKey: .transcribeStyle))
            .flatMap(TranscribeStyle.init(rawValue:))
        notesStyle = (try c.decodeIfPresent(String.self, forKey: .notesStyle))
            .flatMap(NotesStyle.init(rawValue:))
    }

    public var canTranscribe: Bool { transcribeStyle != nil }
    public var canWriteNotes: Bool { notesStyle != nil }
    /// Keychain account holding this provider's API key.
    public var keyAccount: String { "apikey.\(id)" }
    /// True iff at least one of this provider's configured styles requires an
    /// API key. Mirrors the exact exemptions `AppState.hasKey` has always
    /// applied: a provider needs no key when its transcription style is
    /// `.offline`, or its notes style is on-device/local-subprocess (`.apple`,
    /// `.qwenMLX`, `.codexCLI`) — regardless of the other slot.
    public var needsAPIKey: Bool {
        (transcribeStyle?.requiresAPIKey ?? false) || (notesStyle?.requiresAPIKey ?? false)
    }
}

public enum ProviderCatalog {
    /// Built-in offline transcription provider ids — referenced by AppState to
    /// pick the matching runtime/coordinator/engine config instead of a
    /// hardcoded string at each call site.
    public static let offlineWhisperID = "offline-whisper"
    public static let offlineQwen3ASRID = "offline-qwen3-asr"

    /// The offline transcription engine id + pinned model repo for the given
    /// transcription provider id, in one place instead of a ternary repeated
    /// at every call site.
    public static func offlineEngineConfig(for transcriptionProviderID: String) -> (engine: String, model: String) {
        transcriptionProviderID == offlineQwen3ASRID ? (qwenASREngine, qwenASRModel) : (offlineEngine, offlineModel)
    }

    /// Built-in presets. Models are sensible defaults; users can override them and
    /// add fully custom OpenAI-compatible providers.
    public static let builtIn: [Provider] = [
        Provider(id: "gemini", name: "Google Gemini",
                 baseURL: "https://generativelanguage.googleapis.com",
                 transcribeStyle: .gemini, transcribeModel: "gemini-flash-latest",
                 notesStyle: .gemini, notesModel: "gemini-flash-latest",
                 keyHelp: "https://aistudio.google.com/apikey"),
        Provider(id: "openai", name: "OpenAI",
                 baseURL: "https://api.openai.com/v1",
                 transcribeStyle: .whisper, transcribeModel: "whisper-1",
                 notesStyle: .chat, notesModel: "gpt-4o-mini",
                 keyHelp: "https://platform.openai.com/api-keys"),
        Provider(id: "groq", name: "Groq (Whisper + Llama)",
                 baseURL: "https://api.groq.com/openai/v1",
                 transcribeStyle: .whisper, transcribeModel: "whisper-large-v3-turbo",
                 notesStyle: .chat, notesModel: "llama-3.3-70b-versatile",
                 keyHelp: "https://console.groq.com/keys"),
        Provider(id: offlineWhisperID, name: "Offline / Local Whisper",
                 baseURL: "", transcribeStyle: .offline,
                 transcribeModel: "mlx-community/whisper-large-v3-mlx"),
        Provider(id: offlineQwen3ASRID, name: "Offline / Local Qwen3-ASR",
                 baseURL: "", transcribeStyle: .offline,
                 transcribeModel: "mlx-community/Qwen3-ASR-1.7B-4bit"),
        Provider(id: "apple-foundation-models", name: "Apple On-Device",
                 baseURL: "", notesStyle: .apple, notesModel: "System Language Model"),
        Provider(id: "qwen-mlx-local", name: "Local Qwen 4B · MLX",
                 baseURL: "", notesStyle: .qwenMLX,
                 notesModel: "mlx-community/Qwen3-4B-Instruct-2507-4bit"),
        Provider(id: "codex-cli", name: "Codex CLI (ChatGPT subscription)",
                 baseURL: "", notesStyle: .codexCLI,
                 notesModel: "gpt-6-luna", notesReasoningEffort: "none"),
        Provider(id: "deepseek", name: "DeepSeek (深度求索)",
                 baseURL: "https://api.deepseek.com/v1",
                 notesStyle: .chat, notesModel: "deepseek-v4-pro",
                 keyHelp: "https://platform.deepseek.com/api_keys"),
        Provider(id: "moonshot", name: "Moonshot · Kimi (月之暗面)",
                 baseURL: "https://api.moonshot.ai/v1",
                 notesStyle: .chat, notesModel: "kimi-k3",
                 keyHelp: "https://platform.moonshot.ai/console/api-keys"),
        Provider(id: "xai", name: "xAI · Grok",
                 baseURL: "https://api.x.ai/v1",
                 notesStyle: .chat, notesModel: "grok-2-latest",
                 keyHelp: "https://console.x.ai"),
    ]

    /// A blank custom provider template (OpenAI-compatible). The user fills in the
    /// base URL, model, and key.
    public static func newCustom(id: String) -> Provider {
        Provider(id: id, name: "Custom", baseURL: "https://",
                 transcribeStyle: nil, transcribeModel: nil,
                 notesStyle: .chat, notesModel: "",
                 keyHelp: nil, isCustom: true)
    }
}
