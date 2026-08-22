// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// A user-selectable AI provider. The pipeline has two slots — a transcription
/// provider (audio → transcript) and a notes provider (transcript → minutes +
/// summary) — so you can mix e.g. Gemini transcription with DeepSeek notes.
/// Everything is bring-your-own-key (stored in Keychain by `keyAccount`).
public struct Provider: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var baseURL: String
    /// "gemini", "whisper" (OpenAI-compatible), "offline" (bundled worker), or nil.
    public var transcribeStyle: String?
    public var transcribeModel: String?
    /// "gemini", "chat" (OpenAI-compatible), "apple" (Foundation Models),
    /// "qwen-mlx" (app-managed MLX-LM), or nil.
    public var notesStyle: String?
    public var notesModel: String?
    public var keyHelp: String?
    public var isCustom: Bool

    public init(id: String, name: String, baseURL: String,
                transcribeStyle: String? = nil, transcribeModel: String? = nil,
                notesStyle: String? = nil, notesModel: String? = nil,
                keyHelp: String? = nil, isCustom: Bool = false) {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.transcribeStyle = transcribeStyle; self.transcribeModel = transcribeModel
        self.notesStyle = notesStyle; self.notesModel = notesModel
        self.keyHelp = keyHelp; self.isCustom = isCustom
    }

    public var canTranscribe: Bool { transcribeStyle != nil }
    public var canWriteNotes: Bool { notesStyle != nil }
    /// Keychain account holding this provider's API key.
    public var keyAccount: String { "apikey.\(id)" }
}

public enum ProviderCatalog {
    /// Built-in presets. Models are sensible defaults; users can override them and
    /// add fully custom OpenAI-compatible providers.
    public static let builtIn: [Provider] = [
        Provider(id: "gemini", name: "Google Gemini",
                 baseURL: "https://generativelanguage.googleapis.com",
                 transcribeStyle: "gemini", transcribeModel: "gemini-flash-latest",
                 notesStyle: "gemini", notesModel: "gemini-flash-latest",
                 keyHelp: "https://aistudio.google.com/apikey"),
        Provider(id: "openai", name: "OpenAI",
                 baseURL: "https://api.openai.com/v1",
                 transcribeStyle: "whisper", transcribeModel: "whisper-1",
                 notesStyle: "chat", notesModel: "gpt-4o-mini",
                 keyHelp: "https://platform.openai.com/api-keys"),
        Provider(id: "groq", name: "Groq (Whisper + Llama)",
                 baseURL: "https://api.groq.com/openai/v1",
                 transcribeStyle: "whisper", transcribeModel: "whisper-large-v3-turbo",
                 notesStyle: "chat", notesModel: "llama-3.3-70b-versatile",
                 keyHelp: "https://console.groq.com/keys"),
        Provider(id: "offline-whisper", name: "Offline / Local Whisper",
                 baseURL: "", transcribeStyle: "offline",
                 transcribeModel: "mlx-community/whisper-large-v3-mlx"),
        Provider(id: "apple-foundation-models", name: "Apple On-Device",
                 baseURL: "", notesStyle: "apple", notesModel: "System Language Model"),
        Provider(id: "qwen-mlx-local", name: "Local Qwen 8B · MLX",
                 baseURL: "", notesStyle: "qwen-mlx",
                 notesModel: "mlx-community/Qwen3-8B-4bit"),
        Provider(id: "deepseek", name: "DeepSeek (深度求索)",
                 baseURL: "https://api.deepseek.com/v1",
                 notesStyle: "chat", notesModel: "deepseek-v4-pro",
                 keyHelp: "https://platform.deepseek.com/api_keys"),
        Provider(id: "moonshot", name: "Moonshot · Kimi (月之暗面)",
                 baseURL: "https://api.moonshot.ai/v1",
                 notesStyle: "chat", notesModel: "kimi-k3",
                 keyHelp: "https://platform.moonshot.ai/console/api-keys"),
        Provider(id: "xai", name: "xAI · Grok",
                 baseURL: "https://api.x.ai/v1",
                 notesStyle: "chat", notesModel: "grok-2-latest",
                 keyHelp: "https://console.x.ai"),
    ]

    /// A blank custom provider template (OpenAI-compatible). The user fills in the
    /// base URL, model, and key.
    public static func newCustom(id: String) -> Provider {
        Provider(id: id, name: "Custom", baseURL: "https://",
                 transcribeStyle: nil, transcribeModel: nil,
                 notesStyle: "chat", notesModel: "",
                 keyHelp: nil, isCustom: true)
    }
}
