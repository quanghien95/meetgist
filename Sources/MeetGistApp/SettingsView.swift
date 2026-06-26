// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            GroupBox("AI provider (bring your own key)") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: $state.provider) {
                        ForEach(ProviderID.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    HStack {
                        SecureField("API key", text: $key)
                        Button("Save") { state.saveKey(key); key = "" }
                            .disabled(key.isEmpty)
                    }
                    HStack {
                        TextField("Model (default \(GeminiPipeline.defaultModel))", text: $model)
                        Button("Set") { state.saveModel(model); model = "" }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: state.hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .foregroundStyle(state.hasKey ? .green : .orange)
                        Text(state.hasKey
                             ? "A key is saved in your Keychain. Model: \(state.model)"
                             : "No key yet. Gemini has a free tier — get one at aistudio.google.com/apikey.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }

            GroupBox("Recordings folder") {
                HStack {
                    Text(state.outputDir.path).lineLimit(1).truncationMode(.middle)
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { chooseFolder() }
                }.padding(6)
            }

            GroupBox("Permissions") {
                Text("On first recording macOS will ask for **Screen Recording** (system audio) and **Microphone**. Grant both in System Settings → Privacy & Security, then record again.")
                    .font(.callout).foregroundStyle(.secondary).padding(6)
            }

            Spacer()
            Text("MeetGist is free and open source (AGPL-3.0). Your audio stays on your Mac; only transcription requests go to the provider whose key you supplied.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520, height: 470)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.outputDir
        if panel.runModal() == .OK, let url = panel.url { state.outputDir = url }
    }
}
