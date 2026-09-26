// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct ProviderCatalogTests {
    @Test func offlineProviderDoesNotBecomeANotesProvider() {
        let offline = ProviderCatalog.builtIn.first { $0.id == "offline-whisper" }
        #expect(offline?.transcribeStyle == .offline)
        #expect(offline?.transcribeModel == "mlx-community/whisper-large-v3-mlx")
        #expect(offline?.canWriteNotes == false)
        #expect(ProviderCatalog.builtIn.first { $0.id == "gemini" }?.notesStyle == .gemini)
        #expect(ProviderCatalog.builtIn.first { $0.id == "openai" }?.notesStyle == .chat)
        #expect(ProviderCatalog.builtIn.first { $0.id == "groq" }?.notesStyle == .chat)
    }

    @Test func existingCloudNotesStillRequireKeysAndUseTheirConfiguredModels() throws {
        for id in ["gemini", "openai", "groq"] {
            let provider = try #require(ProviderCatalog.builtIn.first { $0.id == id })
            #expect(throws: (any Error).self) {
                try Pipelines.makeNotesWriter(notes: provider, notesKey: nil)
            }
            let writer = try Pipelines.makeNotesWriter(notes: provider, notesKey: "test-key")
            let model = try #require(provider.notesModel)
            #expect(writer.label == model)
        }
    }

    // MARK: - Capability table (P1 §2: de-stringified TranscribeStyle/NotesStyle)

    private struct ExpectedCapabilities {
        let needsAPIKey: Bool
        let canTranscribe: Bool
        let canWriteNotes: Bool
    }

    /// One row per built-in provider, capturing the capability semantics that
    /// existed before `transcribeStyle`/`notesStyle` were de-stringified —
    /// this is the behavior-preservation check for that refactor.
    private static let expectedCapabilities: [String: ExpectedCapabilities] = [
        "gemini": ExpectedCapabilities(needsAPIKey: true, canTranscribe: true, canWriteNotes: true),
        "openai": ExpectedCapabilities(needsAPIKey: true, canTranscribe: true, canWriteNotes: true),
        "groq": ExpectedCapabilities(needsAPIKey: true, canTranscribe: true, canWriteNotes: true),
        ProviderCatalog.offlineWhisperID: ExpectedCapabilities(needsAPIKey: false, canTranscribe: true, canWriteNotes: false),
        ProviderCatalog.offlineQwen3ASRID: ExpectedCapabilities(needsAPIKey: false, canTranscribe: true, canWriteNotes: false),
        "apple-foundation-models": ExpectedCapabilities(needsAPIKey: false, canTranscribe: false, canWriteNotes: true),
        "qwen-mlx-local": ExpectedCapabilities(needsAPIKey: false, canTranscribe: false, canWriteNotes: true),
        "codex-cli": ExpectedCapabilities(needsAPIKey: false, canTranscribe: false, canWriteNotes: true),
        "deepseek": ExpectedCapabilities(needsAPIKey: true, canTranscribe: false, canWriteNotes: true),
        "moonshot": ExpectedCapabilities(needsAPIKey: true, canTranscribe: false, canWriteNotes: true),
        "xai": ExpectedCapabilities(needsAPIKey: true, canTranscribe: false, canWriteNotes: true),
    ]

    @Test func builtInProviderCapabilitiesMatchPreDeStringifyBehavior() throws {
        // Guards against silently adding/removing a built-in provider without
        // updating this table.
        #expect(Set(ProviderCatalog.builtIn.map(\.id)) == Set(Self.expectedCapabilities.keys))
        for provider in ProviderCatalog.builtIn {
            let expected = try #require(Self.expectedCapabilities[provider.id],
                                        "no expected capabilities for \(provider.id)")
            #expect(provider.needsAPIKey == expected.needsAPIKey, "\(provider.id).needsAPIKey")
            #expect(provider.canTranscribe == expected.canTranscribe, "\(provider.id).canTranscribe")
            #expect(provider.canWriteNotes == expected.canWriteNotes, "\(provider.id).canWriteNotes")
        }
    }

    @Test func makeNotesWriterThrowsMissingKeyOnlyForKeyRequiringStyles() throws {
        for provider in ProviderCatalog.builtIn where provider.canWriteNotes {
            switch provider.notesStyle {
            case .gemini, .chat:
                do {
                    _ = try Pipelines.makeNotesWriter(notes: provider, notesKey: nil)
                    Issue.record("\(provider.id) should have required an API key")
                } catch PipelineError.missingKey(let name) {
                    #expect(name == provider.name)
                } catch {
                    Issue.record("\(provider.id) threw \(error) instead of missingKey")
                }
            case .apple, .qwenMLX, .codexCLI:
                // On-device / local-subprocess styles must build successfully
                // without a key.
                _ = try Pipelines.makeNotesWriter(notes: provider, notesKey: nil)
            case nil:
                break
            }
        }
    }

    @Test func makeThrowsMissingKeyOnlyForKeyRequiringTranscriptionStyles() throws {
        for provider in ProviderCatalog.builtIn where provider.canTranscribe {
            switch provider.transcribeStyle {
            case .gemini, .whisper:
                do {
                    _ = try Pipelines.make(transcription: provider, transcriptionKey: nil,
                                          notes: provider, notesKey: nil)
                    Issue.record("\(provider.id) should have required a transcription API key")
                } catch PipelineError.missingKey(let name) {
                    #expect(name == provider.name)
                } catch {
                    Issue.record("\(provider.id) threw \(error) instead of missingKey")
                }
            case .offline, nil:
                break // offline transcription never goes through Pipelines.make
            }
        }
    }

    // MARK: - Persistence compatibility (custom providers are `[Provider]` JSON
    // in UserDefaults; decoding must tolerate unknown/removed style strings).

    @Test func legacyJSONWithoutNotesReasoningEffortDecodes() throws {
        let json = """
        [{"id":"custom-legacy","name":"Custom","baseURL":"https://api.example.com/v1",
          "notesStyle":"chat","notesModel":"some-model","isCustom":true}]
        """
        let providers = try JSONDecoder().decode([Provider].self, from: Data(json.utf8))
        #expect(providers.count == 1)
        #expect(providers[0].id == "custom-legacy")
        #expect(providers[0].notesStyle == .chat)
        #expect(providers[0].transcribeStyle == nil)
        #expect(providers[0].notesReasoningEffort == nil)
    }

    @Test func unknownStyleDecodesToNilWithoutLosingTheRestOfTheArray() throws {
        let json = """
        [{"id":"custom-1","name":"Custom1","baseURL":"https://a.example.com",
          "transcribeStyle":"some-future-engine","notesStyle":"chat",
          "notesModel":"m1","isCustom":true},
         {"id":"custom-2","name":"Custom2","baseURL":"https://b.example.com",
          "notesStyle":"a-removed-style","notesModel":"m2","isCustom":true}]
        """
        let providers = try JSONDecoder().decode([Provider].self, from: Data(json.utf8))
        #expect(providers.count == 2)
        #expect(providers[0].id == "custom-1")
        #expect(providers[0].transcribeStyle == nil, "unknown style must decode to nil, not fail")
        #expect(providers[0].notesStyle == .chat)
        #expect(providers[1].id == "custom-2")
        #expect(providers[1].notesStyle == nil, "removed style must decode to nil, not fail")
    }

    @Test func encodingProviderStylesProducesTheSameRawStringsAsBefore() throws {
        let codex = try #require(ProviderCatalog.builtIn.first { $0.id == "codex-cli" })
        let codexJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(codex)) as? [String: Any]
        #expect(codexJSON?["notesStyle"] as? String == "codex-cli")
        #expect(codexJSON?["transcribeStyle"] == nil)

        let qwen = try #require(ProviderCatalog.builtIn.first { $0.id == "qwen-mlx-local" })
        #expect((try JSONSerialization.jsonObject(with: JSONEncoder().encode(qwen))
                 as? [String: Any])?["notesStyle"] as? String == "qwen-mlx")

        let offline = try #require(ProviderCatalog.builtIn.first { $0.id == ProviderCatalog.offlineWhisperID })
        #expect((try JSONSerialization.jsonObject(with: JSONEncoder().encode(offline))
                 as? [String: Any])?["transcribeStyle"] as? String == "offline")

        let gemini = try #require(ProviderCatalog.builtIn.first { $0.id == "gemini" })
        let geminiJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(gemini)) as? [String: Any]
        #expect(geminiJSON?["transcribeStyle"] as? String == "gemini")
        #expect(geminiJSON?["notesStyle"] as? String == "gemini")
    }

    @Test func roundTrippingBuiltInProvidersPreservesEveryField() throws {
        for provider in ProviderCatalog.builtIn {
            let decoded = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(provider))
            #expect(decoded == provider)
        }
    }
}
