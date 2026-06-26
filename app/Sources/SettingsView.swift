// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit
import KeyboardShortcuts

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
            }.padding(6)
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
            TextField("Model (e.g. deepseek-chat)", text: $model)
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
