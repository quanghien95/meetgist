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
                Button(loc.t(L.done)) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
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
                                }.labelsHidden().pickerStyle(.segmented)
                            }
                        }.padding(6)
                    }

                    // Hotkey
                    GroupBox(loc.t(L.hotkey)) {
                        HStack {
                            Text("\(loc.t(L.start)) / \(loc.t(L.stop))").frame(width: 160, alignment: .leading)
                            KeyboardShortcuts.Recorder(for: .toggleRecord)
                            Spacer()
                        }.padding(6)
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
                                Button("Change…") { chooseFolder() }
                            }
                            Toggle(loc.t(L.autoTranscribe), isOn: $state.autoTranscribe)
                            LaunchAtLoginToggle().environmentObject(loc)
                        }.padding(6)
                    }

                    // AI provider (v1.1 slots)
                    GroupBox(loc.t(L.aiProvider)) {
                        VStack(alignment: .leading, spacing: 14) {
                            ProviderSlot(title: "Transcription  ·  audio → text",
                                         providers: state.transcriptionProviders,
                                         selection: $state.transcriptionProviderID, slot: "transcribe")
                            ProviderSlot(title: "Notes  ·  text → minutes & summary",
                                         providers: state.notesProviders,
                                         selection: $state.notesProviderID, slot: "notes")
                            CustomProvidersView()
                        }.padding(6)
                    }

                    TemplateSettings().environmentObject(state).environmentObject(loc)

                    GroupBox(loc.t(L.privacy)) {
                        Text(loc.t(L.privacyStatement)).font(.callout).foregroundStyle(.secondary).padding(6)
                    }
                    GroupBox(loc.t(L.about)) {
                        Text(loc.t(L.aboutFree)).font(.callout).foregroundStyle(.secondary).padding(6)
                    }
                }.padding()
            }
        }
        .frame(width: 600, height: 680)
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
    let title: String
    let providers: [Provider]
    @Binding var selection: String
    let slot: String
    @State private var keyInput = ""
    @State private var modelInput = ""

    private var selected: Provider { providers.first { $0.id == selection } ?? providers.first ?? ProviderCatalog.builtIn[0] }
    private var defaultModel: String { slot == "transcribe" ? (selected.transcribeModel ?? "") : (selected.notesModel ?? "") }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $selection) {
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
                if selected.transcribeStyle == "offline" && slot == "transcribe" {
                    OfflineProviderSettings()
                } else if selected.notesStyle == "apple" && slot == "notes" {
                    AppleOnDeviceProviderSettings()
                } else if selected.notesStyle == "qwen-mlx" && slot == "notes" {
                    QwenLocalNotesProviderSettings()
                } else {
                    HStack {
                        SecureField(state.hasKey(selected) ? "Key saved — paste to replace" : "API key", text: $keyInput)
                        Button("Save") { state.saveKey(keyInput, for: selected); keyInput = "" }
                            .disabled(keyInput.isEmpty)
                    }
                    HStack {
                        TextField("Model (default \(defaultModel))", text: $modelInput)
                        Button("Set") { state.setModel(modelInput, for: selected, slot: slot); modelInput = "" }
                            .disabled(modelInput.isEmpty)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: state.hasKey(selected) ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .foregroundStyle(state.hasKey(selected) ? .green : .orange)
                        let override = state.modelOverride(selected, slot: slot)
                        Text(state.hasKey(selected)
                             ? "Key set · model: \(override.isEmpty ? defaultModel : override)"
                             : "No key yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let help = selected.keyHelp, let u = URL(string: help) {
                            Spacer(); Link("Get a key ↗", destination: u).font(.callout)
                        }
                    }
                }
            }.padding(6)
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
            Text("Model download: approximately \(ByteCountFormatter.string(fromByteCount: OfflineRuntimeManager.modelDownloadBytes, countStyle: .decimal)). Python runtime and packages need additional space.")
                .font(.caption).foregroundStyle(.secondary)
            if state.offlineRuntime.state == .installing {
                ProgressView(value: state.offlineRuntime.installProgress)
            }
            HStack {
                Text("Language").frame(width: 100, alignment: .leading)
                Picker("", selection: $state.offlineLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Chinese").tag("zh")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                }.labelsHidden()
            }
            TextField("Optional technical vocabulary", text: $state.offlineVocabulary)
            Text("Used as an initial transcription prompt. One local job and one five-minute chunk run at a time.")
                .font(.caption).foregroundStyle(.secondary)
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
                Label("Offline Local Whisper requires Apple Silicon.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.offlineRuntime.installDetail, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

struct AppleOnDeviceProviderSettings: View {
    private var availability: AppleFoundationModelsAvailability {
        AppleFoundationModelsSupport.availability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: availability.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(availability.isReady ? .green : Theme.amber)
                Text(availability.message).font(.callout).foregroundStyle(.secondary)
            }
            Text("Apple Intelligence processes the transcript on-device. The system model is managed by macOS; MeetGist does not download a separate model.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct QwenLocalNotesProviderSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    @State private var showLastRunMetrics = false

    private var metricsURL: URL {
        state.localNotesRuntime.root.appendingPathComponent("last-run-metrics.json")
    }

    private var lastRunMetrics: String? {
        try? String(contentsOf: metricsURL, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Qwen3 8B · MLX-LM · 4-bit · Apple Silicon").font(.callout)
                Spacer()
                runtimeAction
            }
            runtimeStatus
            Text("Model download: approximately \(ByteCountFormatter.string(fromByteCount: LocalNotesRuntimeManager.modelDownloadBytes, countStyle: .decimal)). Python runtime and packages need additional space.")
                .font(.caption).foregroundStyle(.secondary)
            if state.localNotesRuntime.state == .installing {
                ProgressView(value: state.localNotesRuntime.installProgress)
            }
            Text("Runs fully offline after setup. Long transcripts are summarized in local chunks, then reduced before final Meeting Minutes generation. No cloud fallback.")
                .font(.caption).foregroundStyle(.secondary)
            if lastRunMetrics != nil {
                Button("Last run metrics…") { showLastRunMetrics = true }
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $showLastRunMetrics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local Qwen · Last run metrics").font(.headline)
                ScrollView {
                    Text(lastRunMetrics ?? "Metrics file is no longer available.")
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
                Label("Local Qwen Notes requires Apple Silicon.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
        case .installing:
            Label(state.localNotesRuntime.installDetail,
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label(loc.t(L.ready), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.amber)
        }
    }
}

struct CustomProvidersView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        GroupBox("Custom providers (OpenAI-compatible · for Notes)") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.customProviders) { p in CustomProviderRow(initial: p) }
                Button { state.addCustomProvider() } label: { Label("Add custom provider", systemImage: "plus") }
                Text("Add any OpenAI-compatible chat API — DeepSeek, Moonshot/Kimi, a local server, etc. They appear in the Notes picker above.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}

struct CustomProviderRow: View {
    @EnvironmentObject var state: AppState
    let initial: Provider
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var keyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $name)
                Button(role: .destructive) { state.removeCustom(initial) } label: { Image(systemName: "trash") }
            }
            TextField("Base URL (e.g. https://api.deepseek.com/v1)", text: $baseURL)
            TextField("Model (e.g. deepseek-v4-pro)", text: $model)
            HStack {
                SecureField(state.hasKey(initial) ? "Key saved — paste to replace" : "API key", text: $keyInput)
                Button("Save") {
                    var p = initial
                    p.name = name.isEmpty ? "Custom" : name
                    p.baseURL = baseURL
                    p.notesModel = model
                    state.updateCustom(p)
                    if !keyInput.isEmpty { state.saveKey(keyInput, for: p); keyInput = "" }
                    state.status = "Saved \(p.name)."
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
    @State private var micOK = false
    @State private var screenOK = false

    var body: some View {
        GroupBox(loc.t(L.audio)) {
            VStack(alignment: .leading, spacing: 8) {
                permRow(loc.t(L.microphone), ok: micOK, pane: "Privacy_Microphone")
                permRow(loc.t(L.screenRecording), ok: screenOK, pane: "Privacy_ScreenCapture")
            }
            .padding(6)
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
    @State private var on = false
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
                    .background(Theme.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                    .disabled(!state.useTemplate)
                    .opacity(state.useTemplate ? 1 : 0.5)
                HStack {
                    Button(loc.t(L.loadFromFile)) { loadFile() }
                    Spacer()
                }
                Text(loc.t(L.templateHint)).font(.caption).foregroundStyle(.secondary)
            }.padding(6)
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
