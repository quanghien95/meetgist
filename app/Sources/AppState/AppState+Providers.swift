// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import MeetGistKit

// MARK: - Providers (v1.1)
extension AppState {
    var allProviders: [Provider] { ProviderCatalog.builtIn + customProviders }
    var transcriptionProviders: [Provider] { allProviders.filter { $0.canTranscribe } }
    var notesProviders: [Provider] { allProviders.filter { $0.canWriteNotes } }
    func provider(_ id: String) -> Provider? { allProviders.first { $0.id == id } }
    var transcriptionProvider: Provider { provider(transcriptionProviderID) ?? ProviderCatalog.builtIn[0] }
    var notesProvider: Provider { provider(notesProviderID) ?? ProviderCatalog.builtIn[0] }
    func effective(_ p: Provider) -> Provider {
        var e = p; let d = defaults
        if let m = d.string(forKey: Keys.modelOverride(providerID: p.id, slot: .transcribe)), !m.isEmpty { e.transcribeModel = m }
        if let m = d.string(forKey: Keys.modelOverride(providerID: p.id, slot: .notes)), !m.isEmpty { e.notesModel = m }
        if p.notesStyle == .codexCLI,
           let effort = d.string(forKey: Keys.codexEffort(providerID: p.id)), !effort.isEmpty {
            e.notesReasoningEffort = effort
        }
        return e
    }
    func key(for p: Provider) -> String? { keyLookup(p.keyAccount) }
    func hasKey(_ p: Provider) -> Bool {
        !p.needsAPIKey || keyLookup(p.keyAccount) != nil
    }
    func saveKey(_ k: String, for p: Provider) {
        do {
            try keyStore(k.trimmingCharacters(in: .whitespacesAndNewlines), p.keyAccount)
        } catch {
            lastError = error.localizedDescription
            status = tr(L.couldNotSaveAPIKey)
        }
        refreshKeyFlag()
    }
    func setModel(_ m: String, for p: Provider, slot: ProviderModelSlot) {
        defaults.set(m.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: Keys.modelOverride(providerID: p.id, slot: slot))
        objectWillChange.send()
        if slot == .live { liveAssistProviderDidChange() }
    }
    func modelOverride(_ p: Provider, slot: ProviderModelSlot) -> String {
        defaults.string(forKey: Keys.modelOverride(providerID: p.id, slot: slot)) ?? ""
    }
    func setCodexReasoningEffort(_ effort: String, for p: Provider) {
        defaults.set(effort, forKey: Keys.codexEffort(providerID: p.id))
        objectWillChange.send()
    }
    func codexReasoningEffort(for p: Provider) -> String {
        defaults.string(forKey: Keys.codexEffort(providerID: p.id)) ?? (p.notesReasoningEffort ?? "none")
    }
    // A UUID keeps every id unique regardless of how many custom providers
    // exist or have been removed; existing ids are untouched. See P3.
    func addCustomProvider() { customProviders.append(ProviderCatalog.newCustom(id: "custom-\(UUID().uuidString)")) }
    func updateCustom(_ p: Provider) { if let i = customProviders.firstIndex(where: { $0.id == p.id }) { customProviders[i] = p } }
    func removeCustom(_ p: Provider) { customProviders.removeAll { $0.id == p.id }; if transcriptionProviderID == p.id { transcriptionProviderID = "gemini" }; if notesProviderID == p.id { notesProviderID = "gemini" } }
    var usesOfflineTranscription: Bool { transcriptionProvider.transcribeStyle?.isLocal ?? false }
    var usesLocalNotes: Bool { notesProvider.notesStyle?.isOnDevice ?? false }
    var canStartTranscription: Bool {
        usesOfflineTranscription ? activeOfflineRuntime.state == .ready : hasKey(transcriptionProvider)
    }
    /// The offline runtime/coordinator pair for the currently selected
    /// transcription provider. Each local engine (Whisper, Qwen3-ASR) has its
    /// own fully independent runtime and job coordinator, so switching the
    /// provider never mixes up install state or in-flight jobs between them.
    /// `internal` (not `private`): read from `AppState+Recording.swift`
    /// (`finishNewSession`) and `AppState+Processing.swift` (`processOffline`,
    /// `retranscribeOffline`).
    var activeOfflineRuntime: any OfflineTranscriptionRuntime {
        transcriptionProviderID == ProviderCatalog.offlineQwen3ASRID ? qwenASRRuntime : offlineRuntime
    }
    var activeOfflineCoordinator: OfflineJobCoordinator {
        transcriptionProviderID == ProviderCatalog.offlineQwen3ASRID ? qwenASRCoordinator : offlineCoordinator
    }
    /// The one place that checks readiness for a notes style that depends on
    /// an app runtime manager (Local Qwen install state, Apple availability,
    /// Codex CLI installed) — `canGenerateMinutes`, `setupRequiredStatus`, and
    /// `generateMinutes`'s error branch all read from this instead of each
    /// re-implementing their own switch. No `default:` case, so adding a
    /// `NotesStyle` case forces updating this switch. `internal` (not
    /// `private`): called from `AppState+Processing.swift`'s `generateMinutes`.
    func notesReadiness(for provider: Provider) -> NotesReadiness {
        switch provider.notesStyle {
        case .apple:
            let availability = AppleFoundationModelsSupport.availability
            return NotesReadiness(isReady: availability.isReady,
                                   setupMessage: availability.message,
                                   unavailableStatus: tr(L.appleOnDeviceUnavailable),
                                   unavailableError: availability.message)
        case .qwenMLX:
            return NotesReadiness(isReady: localNotesRuntime.state == .ready,
                                   setupMessage: tr(L.installLocalQwenNotesSettings),
                                   unavailableStatus: tr(L.localQwenNotesNotInstalled),
                                   unavailableError: tr(L.installQwen3InSettings))
        case .codexCLI:
            return NotesReadiness(isReady: CodexCLIAvailability.isInstalled,
                                   setupMessage: tr(L.installCodexCLILogin),
                                   unavailableStatus: tr(L.codexCLIUnavailable),
                                   unavailableError: tr(L.installCodexCLILogin))
        case .gemini, .chat, nil:
            return NotesReadiness(isReady: hasKey(provider),
                                   setupMessage: tr(L.addKeyNotesProvider),
                                   unavailableStatus: tr(L.addKeyNotesProvider),
                                   unavailableError: nil)
        }
    }
    var canGenerateMinutes: Bool { notesReadiness(for: notesProvider).isReady }
    var offlineConfig: OfflineJobConfig {
        let (engine, model) = ProviderCatalog.offlineEngineConfig(for: transcriptionProviderID)
        return OfflineJobConfig(engine: engine, model: model, language: offlineLanguage, vocabulary: offlineVocabulary,
                                chunkSeconds: engine == qwenASREngine ? 30 : 300)
    }
    /// `internal` (not `private`): called from `init` (`AppState.swift`), from
    /// `transcriptionProviderID`/`notesProviderID`'s `didSet` (`AppState.swift`),
    /// from `saveKey`/`saveCustom` (this file), and from every runtime
    /// install/remove in `AppState+Runtimes.swift`.
    func refreshKeyFlag() { hasKeys = canStartTranscription && canGenerateMinutes }
    /// `internal` (not `private`): read from `AppState+Recording.swift`
    /// (`finishNewSession`) and `AppState+Processing.swift` (`processCloud`).
    var setupRequiredStatus: String {
        if !canStartTranscription { return tr(L.addKeyTranscriptionProvider) }
        return notesReadiness(for: notesProvider).setupMessage
    }
    /// `internal` (not `private`): called from `customProviders`'s `didSet`
    /// in `AppState.swift`.
    func saveCustom() { if let data = try? JSONEncoder().encode(customProviders) { defaults.set(data, forKey: Keys.custom) }; refreshKeyFlag() }
}
