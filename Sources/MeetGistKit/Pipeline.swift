// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

public struct PipelineResult: Sendable {
    public let transcript: String
    public let polished: String
    public let summary: String
    public let model: String
    public init(transcript: String, polished: String, summary: String, model: String) {
        self.transcript = transcript
        self.polished = polished
        self.summary = summary
        self.model = model
    }
}

public enum PipelineError: Error, LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case fileNotReady(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key set for \(p). Add one in Settings."
        case .http(let code, let body): return "Request failed (HTTP \(code)): \(body)"
        case .fileNotReady(let s): return "Audio upload didn't become ready: \(s)"
        case .badResponse(let s): return "Unexpected response: \(s)"
        }
    }
}

/// A transcription/notes provider. v1 ships `GeminiPipeline`; the protocol lets
/// free-tier fallbacks (Groq, ElevenLabs, …) be added without touching the app.
public protocol MeetingPipeline: Sendable {
    var providerName: String { get }
    /// Read system.m4a / mic.m4a from `sessionDir`, return transcript + polished +
    /// summary. `progress` reports human-readable status for the UI.
    func process(sessionDir: URL,
                 micExists: Bool,
                 systemExists: Bool,
                 progress: @escaping @Sendable (String) -> Void) async throws -> PipelineResult
}

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case gemini
    // Free-tier fallbacks planned: groq, elevenlabs

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini (free tier)"
        }
    }
    /// Keychain account name for this provider's API key.
    public var keyAccount: String { "apikey.\(rawValue)" }
}

public enum Pipelines {
    /// Build the pipeline for a provider + key. Returns nil if no key is set.
    public static func make(provider: ProviderID, model: String?) -> MeetingPipeline? {
        guard let key = Keychain.get(provider.keyAccount) else { return nil }
        switch provider {
        case .gemini:
            return GeminiPipeline(apiKey: key, model: model ?? GeminiPipeline.defaultModel)
        }
    }
}
