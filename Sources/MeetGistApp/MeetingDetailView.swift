// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import MeetGistKit

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    @State private var tab = "summary.md"

    private let tabs: [(file: String, label: String)] = [
        ("summary.md", "Summary"),
        ("polished.md", "Minutes"),
        ("transcript.md", "Transcript"),
    ]

    private var content: String? { MeetingStore.markdown(tab, in: meeting.dir) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(meeting.title).font(.title3.bold())
                    if let d = meeting.date {
                        Text(d, format: .dateTime.weekday().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(meeting.dir)
                } label: { Label("Reveal", systemImage: "folder") }
                if meeting.hasNotes, let c = content {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Button {
                    state.reprocessSelected()
                } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(state.processing || !state.hasKey)
            }
            .padding()

            Picker("", selection: $tab) {
                ForEach(tabs, id: \.file) { Text($0.label).tag($0.file) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal)

            Divider().padding(.top, 8)

            ScrollView {
                if let c = content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(markdown(c))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    notesPlaceholder.padding(40)
                }
            }
        }
    }

    @ViewBuilder private var notesPlaceholder: some View {
        VStack(spacing: 10) {
            if state.processing {
                ProgressView()
                Text(state.status).foregroundStyle(.secondary)
            } else if !state.hasKey {
                Image(systemName: "key").font(.title)
                Text("Add a free-tier API key in Settings, then press Regenerate.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "doc.text").font(.title).foregroundStyle(.secondary)
                Text("No notes yet for this recording.").foregroundStyle(.secondary)
                Button("Generate notes") { state.reprocessSelected() }
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    // Render markdown, falling back to plain text if it doesn't parse.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        ) ?? AttributedString(s)
    }
}
