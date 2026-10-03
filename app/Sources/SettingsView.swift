// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit
import KeyboardShortcuts
import ServiceManagement
import AVFoundation
import CoreGraphics

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.t(L.settings)).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(loc.t(L.done)) { dismiss() }
                    .buttonStyle(MintButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // General
                    GroupBox(loc.t(L.general)) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(loc.t(L.language)).frame(width: 160, alignment: .leading)
                                Picker("", selection: $loc.lang) {
                                    ForEach(Lang.allCases) { Text(loc.name(of: $0)).tag($0) }
                                }.labelsHidden()
                            }
                            HStack {
                                Text(loc.t(L.recordingPresence)).frame(width: 160, alignment: .leading)
                                Picker("", selection: $state.presence) {
                                    Text(loc.t(L.presenceMenuBar)).tag(Presence.menuBar)
                                    Text(loc.t(L.presenceMini)).tag(Presence.mini)
                                }.labelsHidden().pickerStyle(.segmented).tint(Theme.controlTint)
                            }
                        }
                    }

                    // Hotkey
                    GroupBox(loc.t(L.hotkey)) {
                        HStack {
                            Text("\(loc.t(L.start)) / \(loc.t(L.stop))").frame(width: 160, alignment: .leading)
                            KeyboardShortcuts.Recorder(for: .toggleRecord)
                            Spacer()
                        }
                    }

                    // Audio permissions
                    AudioSettings().environmentObject(loc)

                    // Recording
                    GroupBox(loc.t(L.recordingSection)) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(state.outputDir.path).lineLimit(1).truncationMode(.middle)
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                Spacer()
                                Button(loc.t(L.change)) { chooseFolder() }
                            }
                            Group {
                                Toggle(loc.t(L.autoTranscribe), isOn: $state.autoTranscribe)
                                Toggle(loc.t(L.autoGenerateNotes), isOn: $state.autoGenerateNotes)
                                Toggle(loc.t(L.detectMeetingsLabel), isOn: $state.detectMeetings)
                                LaunchAtLoginToggle().environmentObject(loc)
                            }
                            .tint(Theme.controlTint)
                        }
                    }

                    // AI provider (v1.1 slots)
                    GroupBox(loc.t(L.aiProvider)) {
                        VStack(alignment: .leading, spacing: 14) {
                            ProviderSlot(title: loc.t(L.transcriptionSlotTitle),
                                         providers: state.transcriptionProviders,
                                         selection: $state.transcriptionProviderID, slot: .transcribe)
                            ProviderSlot(title: loc.t(L.notesSlotTitle),
                                         providers: state.notesProviders,
                                         selection: $state.notesProviderID, slot: .notes)
                            CustomProvidersView()
                        }
                    }

                    LiveAssistSettings().environmentObject(state).environmentObject(loc)

                    GroupBox(loc.t(L.notesLanguageSection)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(loc.t(L.outputLanguage)).frame(width: 130, alignment: .leading)
                                Picker("", selection: $state.notesLanguage) {
                                    Text(loc.t(L.langVietnamese)).tag("Vietnamese")
                                    Text(loc.t(L.langEnglish)).tag("English")
                                }.labelsHidden().pickerStyle(.segmented).tint(Theme.controlTint).frame(width: 220)
                            }
                            Text(loc.t(L.notesLanguageHint))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    TemplateSettings().environmentObject(state).environmentObject(loc)

                    GroupBox(loc.t(L.postProcessScriptSection)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(loc.t(L.postProcessAutoRun), isOn: $state.postProcessEnabled)
                                .tint(Theme.controlTint)
                            Text(loc.t(L.postProcessDescription))
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $state.postProcessSource)
                                .font(Theme.mono(11))
                                .frame(height: 150)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                            Text("MEETGIST_RECORDING_PATH · MEETGIST_MICROPHONE_PATH · MEETGIST_TRANSCRIPT · MEETGIST_MINUTES · MEETGIST_SUMMARY · MEETGIST_MEETING_TITLE · MEETGIST_MEETING_DATE · MEETGIST_MEETING_DIR · MEETGIST_MEETING_ID")
                                .font(Theme.mono(9)).foregroundStyle(Theme.muted)
                        }
                    }

                    GroupBox(loc.t(L.privacy)) {
                        Text(loc.t(L.privacyStatement)).font(.callout).foregroundStyle(.secondary)
                    }
                    GroupBox(loc.t(L.about)) {
                        Text(loc.t(L.aboutFree)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .groupBoxStyle(CardGroupBoxStyle())
                .padding(20)
            }
        }
        .frame(width: 640, height: 720)
        .background(Theme.bg)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.outputDir
        if panel.runModal() == .OK, let url = panel.url { state.setOutputDir(url) }
    }
}

struct ProviderSlot: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    let title: String
    let providers: [Provider]
    @Binding var selection: String
    let slot: ProviderModelSlot
    @CompatibleState private var keyInput = ""
    @CompatibleState private var modelInput = ""

    private var selected: Provider { providers.first { $0.id == selection } ?? providers.first ?? ProviderCatalog.builtIn[0] }
    private var defaultModel: String { slot == .transcribe ? (selected.transcribeModel ?? "") : (selected.notesModel ?? "") }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(loc.t(L.provider), selection: $selection) {
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
                if selected.transcribeStyle == .offline && slot == .transcribe {
                    if selected.id == ProviderCatalog.offlineQwen3ASRID {
                        QwenASRProviderSettings()
                    } else {
                        OfflineProviderSettings()
                    }
                } else if selected.notesStyle == .apple && slot == .notes {
                    AppleOnDeviceProviderSettings()
                } else if selected.notesStyle == .qwenMLX && slot == .notes {
                    QwenLocalNotesProviderSettings()
                } else if selected.notesStyle == .codexCLI && slot == .notes {
                    CodexCLIProviderSettings()
                } else {
                    HStack {
                        SecureField(state.hasKey(selected) ? loc.t(L.keySavedPasteToReplace) : loc.t(L.apiKey), text: $keyInput)
                        Button(loc.t(L.save)) { state.saveKey(keyInput, for: selected); keyInput = "" }
                            .disabled(keyInput.isEmpty)
                    }
                    HStack {
                        TextField(loc.t(L.modelDefaultLabel(defaultModel)), text: $modelInput)
                        Button(loc.t(L.set)) { state.setModel(modelInput, for: selected, slot: slot); modelInput = "" }
                            .disabled(modelInput.isEmpty)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: state.hasKey(selected) ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .foregroundStyle(state.hasKey(selected) ? Theme.mint : Theme.amber)
                        let override = state.modelOverride(selected, slot: slot)
                        Text(state.hasKey(selected)
                             ? loc.t(L.keySetModelLabel(override.isEmpty ? defaultModel : override))
                             : loc.t(L.noKeyYet))
                            .font(.callout).foregroundStyle(.secondary)
                        if let help = selected.keyHelp, let u = URL(string: help) {
                            Spacer(); Link(loc.t(L.getAKey), destination: u).font(.callout)
                        }
                    }
                }
            }
        }
    }
}

struct OfflineProviderSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MLX Whisper · Large V3 · Apple Silicon").font(.callout)
                Spacer()
                runtimeAction
            }
            runtimeStatus
            Text(loc.t(L.modelDownloadApprox(ByteCountFormatter.string(fromByteCount: OfflineRuntimeManager.modelDownloadBytes, countStyle: .decimal))))
                .font(.caption).foregroundStyle(.secondary)
            if state.offlineRuntime.state == .installing {
                ProgressView(value: state.offlineRuntime.installProgress)
            }
            HStack {
                Text(loc.t(L.language)).frame(width: 100, alignment: .leading)
                Picker("", selection: $state.offlineLanguage) {
                    Text(loc.t(L.langAuto)).tag("auto")
                    Text(loc.t(L.langEnglish)).tag("en")
                    Text(loc.t(L.langChinese)).tag("zh")
                    Text(loc.t(L.langSpanish)).tag("es")
                    Text(loc.t(L.langFrench)).tag("fr")
                    Text(loc.t(L.langGerman)).tag("de")
                    Text(loc.t(L.langJapanese)).tag("ja")
                    Text(loc.t(L.langKorean)).tag("ko")
                }.labelsHidden()
            }
            HotwordsField()
        }
    }

    @ViewBuilder private var runtimeAction: some View {
        switch state.offlineRuntime.state {
        case .notInstalled:
            if OfflineRuntimeManager.isSupported {
                Button(loc.t(L.install)) { state.installOfflineRuntime() }
            }
        case .installing:
            EmptyView()
        case .ready:
            Button(loc.t(L.remove)) { state.removeOfflineRuntime() }
        case .failed:
            Button(loc.t(L.retry)) { state.installOfflineRuntime() }
        }
    }

    @ViewBuilder private var runtimeStatus: some View {
        switch state.offlineRuntime.state {
        case .notInstalled:
            if OfflineRuntimeManager.isSupported {
                Label(loc.t(L.notInstalled), systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(loc.t(L.offlineWhisperRequiresAppleSilicon),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.offlineRuntime.installDetail, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(Theme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

struct QwenASRProviderSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Qwen3-ASR · 1.7B · 4-bit · Apple Silicon").font(.callout)
                Spacer()
                runtimeAction
            }
            runtimeStatus
            Text(loc.t(L.modelDownloadApprox(ByteCountFormatter.string(fromByteCount: Qwen3ASRRuntimeManager.modelDownloadBytes, countStyle: .decimal))))
                .font(.caption).foregroundStyle(.secondary)
            if state.qwenASRRuntime.state == .installing {
                ProgressView(value: state.qwenASRRuntime.installProgress)
            }
            HStack {
                Text(loc.t(L.language)).frame(width: 100, alignment: .leading)
                Picker("", selection: $state.offlineLanguage) {
                    Text(loc.t(L.langAuto)).tag("auto")
                    Text(loc.t(L.langEnglish)).tag("en")
                    Text(loc.t(L.langChinese)).tag("zh")
                    Text(loc.t(L.langSpanish)).tag("es")
                    Text(loc.t(L.langFrench)).tag("fr")
                    Text(loc.t(L.langGerman)).tag("de")
                    Text(loc.t(L.langJapanese)).tag("ja")
                    Text(loc.t(L.langKorean)).tag("ko")
                }.labelsHidden()
            }
            HotwordsField()
            Text(loc.t(L.qwenASRNoTimestampsNote))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var runtimeAction: some View {
        switch state.qwenASRRuntime.state {
        case .notInstalled:
            if Qwen3ASRRuntimeManager.isSupported {
                Button(loc.t(L.install)) { state.installQwenASRRuntime() }
            }
        case .installing:
            EmptyView()
        case .ready:
            Button(loc.t(L.remove)) { state.removeQwenASRRuntime() }
        case .failed:
            Button(loc.t(L.retry)) { state.installQwenASRRuntime() }
        }
    }

    @ViewBuilder private var runtimeStatus: some View {
        switch state.qwenASRRuntime.state {
        case .notInstalled:
            if Qwen3ASRRuntimeManager.isSupported {
                Label(loc.t(L.notInstalled), systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(loc.t(L.offlineQwenASRRequiresAppleSilicon),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.qwenASRRuntime.installDetail, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(Theme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

/// Shared hotwords/context-keywords field for both local engines: Whisper
/// uses it as an `initial_prompt`, Qwen3-ASR as its native `hotwords` list.
struct HotwordsField: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization

    var body: some View {
        HStack(spacing: 6) {
            TextField(loc.t(L.hotwordsPlaceholder), text: $state.offlineVocabulary)
            Menu {
                ForEach(HotwordPresets.all) { preset in
                    Button(preset.name) { state.offlineVocabulary = preset.keywords }
                }
            } label: {
                Label(loc.t(L.preset), systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        Text(loc.t(L.hotwordsHint))
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct AppleOnDeviceProviderSettings: View {
    @EnvironmentObject var loc: Localization
    private var availability: AppleFoundationModelsAvailability {
        AppleFoundationModelsSupport.availability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: availability.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(availability.isReady ? Theme.mint : Theme.amber)
                // `availability.message` is produced by MeetGistKit (out of
                // this file's ownership) and stays English.
                Text(availability.message).font(.callout).foregroundStyle(.secondary)
            }
            Text(loc.t(L.appleOnDeviceDescription))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct QwenLocalNotesProviderSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @CompatibleState private var showLastRunMetrics = false

    private var metricsURL: URL {
        state.localNotesRuntime.root.appendingPathComponent("last-run-metrics.json")
    }

    private var lastRunMetrics: String? {
        try? String(contentsOf: metricsURL, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Qwen3 4B Instruct (2507) · MLX-LM · 4-bit · Apple Silicon").font(.callout)
                Spacer()
                runtimeAction
            }
            runtimeStatus
            Text(loc.t(L.modelDownloadApprox(ByteCountFormatter.string(fromByteCount: LocalNotesRuntimeManager.modelDownloadBytes, countStyle: .decimal))))
                .font(.caption).foregroundStyle(.secondary)
            if state.localNotesRuntime.state == .installing {
                ProgressView(value: state.localNotesRuntime.installProgress)
            }
            Text(loc.t(L.qwenNotesRunsOfflineDescription))
                .font(.caption).foregroundStyle(.secondary)
            if lastRunMetrics != nil {
                Button(loc.t(L.lastRunMetrics)) { showLastRunMetrics = true }
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $showLastRunMetrics) {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t(L.localQwenLastRunMetricsTitle)).font(.headline)
                ScrollView {
                    Text(lastRunMetrics ?? loc.t(L.metricsFileUnavailable))
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(loc.t(L.done)) { showLastRunMetrics = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 500, height: 330)
        }
    }

    @ViewBuilder private var runtimeAction: some View {
        switch state.localNotesRuntime.state {
        case .notInstalled:
            if LocalNotesRuntimeManager.isSupported {
                Button(loc.t(L.install)) { state.installLocalNotesRuntime() }
            }
        case .installing:
            EmptyView()
        case .ready:
            Button(loc.t(L.remove)) { state.removeLocalNotesRuntime() }
        case .failed:
            Button(loc.t(L.retry)) { state.installLocalNotesRuntime() }
        }
    }

    @ViewBuilder private var runtimeStatus: some View {
        switch state.localNotesRuntime.state {
        case .notInstalled:
            if LocalNotesRuntimeManager.isSupported {
                Label(loc.t(L.notInstalled), systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(loc.t(L.localQwenRequiresAppleSilicon),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.localNotesRuntime.installDetail,
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(Theme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

struct CodexCLIProviderSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    private var provider: Provider { state.notesProvider }

    private var effortBinding: Binding<String> {
        Binding(
            get: { state.codexReasoningEffort(for: provider) },
            set: { state.setCodexReasoningEffort($0, for: provider) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // "Codex CLI" and "gpt-6-luna" are product/model names and stay
                // untranslated; only the trailing description is localized.
                Text("Codex CLI · gpt-6-luna · \(loc.t(L.viaChatGPTSubscription))").font(.callout)
                Spacer()
                installStatus
            }
            HStack {
                Text(loc.t(L.reasoningEffort)).frame(width: 130, alignment: .leading)
                Picker("", selection: effortBinding) {
                    Text(loc.t(L.effortNone)).tag("none")
                    Text(loc.t(L.effortLow)).tag("low")
                    Text(loc.t(L.effortMedium)).tag("medium")
                    Text(loc.t(L.effortHigh)).tag("high")
                    Text(loc.t(L.effortExtraHigh)).tag("xhigh")
                    Text(loc.t(L.effortMax)).tag("max")
                }.labelsHidden()
            }
            Text(loc.t(L.codexCLIDescription))
                .font(.caption).foregroundStyle(.secondary)
            Text(loc.t(L.codexCLIBenchmarkNote))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var installStatus: some View {
        if CodexCLIAvailability.isInstalled {
            Label(loc.t(L.codexCLIFound), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(Theme.mint)
        } else {
            Label(loc.t(L.codexCLINotFound),
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

struct CustomProvidersView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    var body: some View {
        GroupBox(loc.t(L.customProvidersSection)) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.customProviders) { p in CustomProviderRow(initial: p) }
                Button { state.addCustomProvider() } label: { Label(loc.t(L.addCustomProvider), systemImage: "plus") }
                Text(loc.t(L.customProvidersHint))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CustomProviderRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    let initial: Provider
    @CompatibleState private var name = ""
    @CompatibleState private var baseURL = ""
    @CompatibleState private var model = ""
    @CompatibleState private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(loc.t(L.nameField), text: $name)
                Button(role: .destructive) { state.removeCustom(initial) } label: { Image(systemName: "trash") }
            }
            TextField(loc.t(L.baseURLPlaceholder), text: $baseURL)
            TextField(loc.t(L.modelPlaceholder), text: $model)
            HStack {
                SecureField(state.hasKey(initial) ? loc.t(L.keySavedPasteToReplace) : loc.t(L.apiKey), text: $keyInput)
                Button(loc.t(L.save)) {
                    var p = initial
                    // "Custom" is the persisted fallback provider name (stored
                    // in Provider.name), not a pure UI label — kept stable
                    // across language switches rather than translated.
                    p.name = name.isEmpty ? "Custom" : name
                    p.baseURL = baseURL
                    p.notesModel = model
                    state.updateCustom(p)
                    if !keyInput.isEmpty { state.saveKey(keyInput, for: p); keyInput = "" }
                    state.status = loc.t(L.savedProviderName(p.name))
                }
            }
            Divider()
        }
        .onAppear {
            name = initial.name; baseURL = initial.baseURL; model = initial.notesModel ?? ""
        }
    }
}

struct AudioSettings: View {
    @EnvironmentObject var loc: Localization
    @CompatibleState private var micOK = false
    @CompatibleState private var screenOK = false

    var body: some View {
        GroupBox(loc.t(L.audio)) {
            VStack(alignment: .leading, spacing: 8) {
                permRow(loc.t(L.microphone), ok: micOK, pane: "Privacy_Microphone")
                permRow(loc.t(L.screenRecording), ok: screenOK, pane: "Privacy_ScreenCapture")
            }
            .onAppear {
                micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                screenOK = CGPreflightScreenCaptureAccess()
            }
        }
    }

    private func permRow(_ name: String, ok: Bool, pane: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .foregroundStyle(ok ? Theme.mint : Theme.amber)
            Text(name).frame(width: 200, alignment: .leading).font(.callout)
            Text(ok ? loc.t(L.granted) : loc.t(L.notGranted)).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !ok {
                Button(loc.t(L.openSystemSettings)) {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @EnvironmentObject var loc: Localization
    @CompatibleState private var on = false
    var body: some View {
        Toggle(loc.t(L.launchAtLogin), isOn: $on)
            .onAppear { on = (SMAppService.mainApp.status == .enabled) }
            .onChange(of: on) { _, v in
                do { try v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                catch { on = (SMAppService.mainApp.status == .enabled) }
            }
    }
}

struct TemplateSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    var body: some View {
        GroupBox(loc.t(L.templateSection)) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(loc.t(L.useTemplateLabel), isOn: $state.useTemplate)
                    .tint(Theme.controlTint)

                // Reference templates — the built-in structures, ready to view and tweak.
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(L.referenceTemplates)).font(.caption).foregroundStyle(.secondary)
                    ForEach(NotesTemplateCatalog.builtIn) { tpl in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tpl.localizedName(zh: loc.effective == .zh)).font(.callout)
                                Text(tpl.localizedDesc(zh: loc.effective == .zh))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(loc.t(L.useAsStartingPoint)) {
                                state.notesTemplate = tpl.localizedBody(zh: loc.effective == .zh)
                                state.useTemplate = true
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }

                TextEditor(text: $state.notesTemplate)
                    .font(Theme.mono(11))
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                    .disabled(!state.useTemplate)
                    .opacity(state.useTemplate ? 1 : 0.5)
                HStack {
                    Button(loc.t(L.loadFromFile)) { loadFile() }
                    Spacer()
                }
                Text(loc.t(L.templateHint)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadFile() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) {
            state.notesTemplate = s
            state.useTemplate = true
        }
    }
}
