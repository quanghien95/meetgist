// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import MeetGistKit

/// Settings → "Live Assist" GroupBox (plan §5.12): enable toggle, provider
/// picker limited to cloud Notes providers, a model override field, the
/// analyze-mic toggle, Live ASR install/remove + status, and a privacy note.
struct LiveAssistSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @CompatibleState private var modelInput = ""

    var body: some View {
        GroupBox(loc.t(L.liveAssistSectionTitle)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(loc.t(L.liveAssistEnableToggle), isOn: Binding(
                    get: { state.liveAssistEnabled },
                    set: { _ in state.toggleLiveAssist() }
                )).tint(Theme.controlTint)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(loc.t(L.liveAssistProviderLabel)).frame(width: 160, alignment: .leading)
                        Picker("", selection: $state.liveAssistProviderID) {
                            Text(loc.t(L.liveAssistProviderDefaultHint)).tag("")
                            ForEach(state.liveAssistProviders) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                    }
                    if let selected = selectedLiveProvider {
                        HStack {
                            TextField(loc.t(L.liveAssistModelOverrideLabel), text: $modelInput)
                            Button(loc.t(L.set)) {
                                state.setModel(modelInput, for: selected, slot: .live)
                                modelInput = ""
                            }.disabled(modelInput.isEmpty)
                        }
                        let override = state.modelOverride(selected, slot: .live)
                        if !override.isEmpty {
                            Text(loc.t(L.keySetModelLabel(override))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(loc.t(L.liveAnalyzeMicToggle), isOn: $state.liveAnalyzeMic).tint(Theme.controlTint)
                Toggle(loc.t(L.liveAutoSuggestToggle), isOn: $state.liveAutoSuggest).tint(Theme.controlTint)

                liveASRRuntimeSection

                Text(loc.t(L.liveAssistPrivacyNote(liveAssistProviderDisplayName)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The provider whose model-override field applies: the explicitly
    /// picked Live Assist provider, else (when left as "default") the Notes
    /// provider — same resolution `AppState+LiveAssist.swift` uses at
    /// runtime, so the field shown here always matches what would actually
    /// be used.
    private var selectedLiveProvider: Provider? {
        let id = state.liveAssistProviderID.isEmpty ? state.notesProviderID : state.liveAssistProviderID
        return state.provider(id)
    }
    private var liveAssistProviderDisplayName: String { selectedLiveProvider?.name ?? state.notesProvider.name }

    @ViewBuilder private var liveASRRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc.t(L.liveASRSectionTitle)).font(.callout)
                Spacer()
                runtimeAction
            }
            runtimeStatus
            Text(loc.t(L.modelDownloadApprox(
                ByteCountFormatter.string(fromByteCount: LiveASRRuntimeManager.modelDownloadBytes, countStyle: .decimal))))
                .font(.caption).foregroundStyle(.secondary)
            if state.liveASRRuntime.state == .installing {
                ProgressView(value: state.liveASRRuntime.installProgress)
            }
        }
    }

    @ViewBuilder private var runtimeAction: some View {
        switch state.liveASRRuntime.state {
        case .notInstalled:
            if LiveASRRuntimeManager.isSupported {
                Button(loc.t(L.install)) { state.installLiveASRRuntime() }
            }
        case .installing:
            EmptyView()
        case .ready:
            Button(loc.t(L.remove)) { state.removeLiveASRRuntime() }
        case .failed:
            Button(loc.t(L.retry)) { state.installLiveASRRuntime() }
        }
    }

    @ViewBuilder private var runtimeStatus: some View {
        switch state.liveASRRuntime.state {
        case .notInstalled:
            if LiveASRRuntimeManager.isSupported {
                Label(loc.t(L.notInstalled), systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(loc.t(L.liveASRRequiresAppleSilicon), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.liveASRRuntime.installDetail, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(Theme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.amber)
        }
    }
}
