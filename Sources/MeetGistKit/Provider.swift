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
    /// "gemini" (audio via Files API), "whisper" (OpenAI-compatible /audio/transcriptions), or nil.
    public var transcribeStyle: String?
    public var transcribeModel: String?
    /// "gemini" (generateContent) or "chat" (OpenAI-compatible /chat/completions), or nil.
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
                 transcribeStyle: "gemini", transcribeModel: "gemini-2.5-flash",
                 notesStyle: "gemini", notesModel: "gemini-2.5-flash",
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
        Provider(id: "deepseek", name: "DeepSeek (深度求索)",
                 baseURL: "https://api.deepseek.com/v1",
                 notesStyle: "chat", notesModel: "deepseek-chat",
                 keyHelp: "https://platform.deepseek.com/api_keys"),
        Provider(id: "moonshot", name: "Moonshot · Kimi (月之暗面)",
                 baseURL: "https://api.moonshot.cn/v1",
                 notesStyle: "chat", notesModel: "moonshot-v1-32k",
                 keyHelp: "https://platform.moonshot.cn/console/api-keys"),
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
