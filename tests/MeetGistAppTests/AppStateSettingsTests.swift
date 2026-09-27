// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import MeetGistKit
@testable import MeetGistApp

/// Covers settings persistence through the injected `UserDefaults` suite, and
/// `notesReadiness`/`hasKeys` for a key-requiring provider, driven through the
/// injected key-lookup closure instead of the real Keychain.
@MainActor
@Suite struct AppStateSettingsTests {
    @Test func settingsRoundTripThroughInjectedUserDefaults() throws {
        let suiteName = "meetgist-apptests-settings-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetgist-appstate-settings-\(UUID().uuidString)")
        let outputDir = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(
            userDefaults: suite,
            initialOutputDir: outputDir,
            keyLookup: { _ in nil },
            offlineRuntime: OfflineRuntimeManager(root: root.appendingPathComponent("OfflineWhisper")),
            qwenASRRuntime: Qwen3ASRRuntimeManager(root: root.appendingPathComponent("Qwen3ASR")),
            localNotesRuntime: LocalNotesRuntimeManager(root: root.appendingPathComponent("LocalNotes"))
        )

        state.autoGenerateNotes = false
        state.postProcessEnabled = true
        state.notesLanguage = "French"
        // Keys mirror AppState's private `Keys` enum literally (it's private,
        // so tests can't reference it directly) — these strings are the
        // persisted contract and must not change without a migration.
        #expect(suite.bool(forKey: "MeetGistAutoGenerateNotes") == false)
        #expect(suite.bool(forKey: "MeetGistPostProcessEnabled") == true)
        #expect(suite.string(forKey: "MeetGistNotesLanguage") == "French")

        let gemini = try #require(ProviderCatalog.builtIn.first { $0.id == "gemini" })
        state.setModel("custom-notes-model", for: gemini, slot: .notes)
        state.setModel("custom-transcribe-model", for: gemini, slot: .transcribe)
        // Exact existing key shape — "model.<id>.<slot>" — must not drift.
        #expect(suite.string(forKey: "model.gemini.notes") == "custom-notes-model")
        #expect(suite.string(forKey: "model.gemini.transcribe") == "custom-transcribe-model")
        #expect(state.modelOverride(gemini, slot: .notes) == "custom-notes-model")
        #expect(state.modelOverride(gemini, slot: .transcribe) == "custom-transcribe-model")
    }

    /// `gemini` needs an API key for both transcription and notes. Without a
    /// key from the injected lookup, neither `hasKeys` nor `canGenerateMinutes`
    /// should be true; with one, both should be.
    @Test func hasKeysAndNotesReadinessReflectInjectedKeyLookup() throws {
        let (withoutKey, cleanupWithout) = try AppStateTestSupport.makeAppState(keyLookup: { _ in nil })
        defer { cleanupWithout() }
        #expect(withoutKey.transcriptionProviderID == "gemini")
        #expect(withoutKey.notesProviderID == "gemini")
        #expect(withoutKey.hasKey(withoutKey.notesProvider) == false)
        #expect(withoutKey.hasKeys == false)
        #expect(withoutKey.canGenerateMinutes == false)

        let (withKey, cleanupWith) = try AppStateTestSupport.makeAppState(keyLookup: { _ in "sk-fake-key" })
        defer { cleanupWith() }
        #expect(withKey.hasKey(withKey.notesProvider) == true)
        #expect(withKey.hasKeys == true)
        #expect(withKey.canGenerateMinutes == true)
    }

    /// A provider that needs no API key (Apple on-device notes) must be ready
    /// regardless of what the key lookup returns.
    @Test func onDeviceNotesProviderNeedsNoKey() throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState(keyLookup: { _ in nil })
        defer { cleanup() }
        let apple = try #require(ProviderCatalog.builtIn.first { $0.id == "apple-foundation-models" })
        #expect(state.hasKey(apple) == true)
    }

    /// saveKey goes through the injected store (never the real Keychain in
    /// tests) and hasKeys reflects it once lookup sees the saved value.
    @Test func saveKeyUsesInjectedStoreAndUpdatesReadiness() throws {
        final class Box: @unchecked Sendable { var keys: [String: String] = [:] }
        let box = Box()
        let (state, cleanup) = try AppStateTestSupport.makeAppState(
            keyLookup: { box.keys[$0] },
            keyStore: { value, account in box.keys[account] = value.isEmpty ? nil : value })
        defer { cleanup() }
        state.transcriptionProviderID = "gemini"
        state.notesProviderID = "gemini"
        #expect(!state.hasKeys)
        state.saveKey("  secret-test-key \n", for: state.transcriptionProvider)
        #expect(box.keys["apikey.gemini"] == "secret-test-key")
        #expect(state.hasKeys)
    }
}
