// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import MeetGistKit

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    let meeting: Meeting
    @State private var tab = Tab.summary

    enum Tab: Hashable { case summary, minutes, transcript }

    private var file: String {
        switch tab { case .summary: return "summary.md"; case .minutes: return "polished.md"; case .transcript: return "transcript.md" }
    }
    private var content: String? { MeetingStore.markdown(file, in: meeting.dir) }
    private var processingThis: Bool { state.state == .processing && state.selectedID == meeting.id }
    private var hasMic: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("mic.m4a").path) }
    private var hasSystem: Bool { FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("system.m4a").path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView {
                if let c = content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(md(c)).textSelection(.enabled).font(Theme.ui(13))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    placeholder.padding(40)
                }
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        if let d = meeting.date {
                            Text(d, format: .dateTime.weekday().month().day().hour().minute())
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        }
                        // Audio tracks status
                        HStack(spacing: 4) {
                            Circle().fill(hasMic ? Theme.mint : Theme.line).frame(width: 6, height: 6)
                            Text(loc.t(L.me)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                            Circle().fill(hasSystem ? Theme.teal : Theme.line).frame(width: 6, height: 6)
                            Text(loc.t(L.system)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    iconButton("doc.on.doc", loc.t(L.copy)) { copy() }
                    iconButton("folder", loc.t(L.reveal)) { NSWorkspace.shared.open(meeting.dir) }
                    iconButton("arrow.clockwise", loc.t(L.regenerate)) { state.reprocessSelected() }
                        .disabled(state.state == .processing || !state.hasKeys)
                }
            }
            HStack(spacing: 6) {
                segTab(loc.t(L.summary), .summary)
                segTab(loc.t(L.minutes), .minutes)
                segTab(loc.t(L.transcript), .transcript)
                Spacer()
            }
        }
        .padding(16)
    }

    private func segTab(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title).font(Theme.mono(11, .medium))
                .foregroundStyle(tab == value ? Theme.bg : Theme.muted)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(tab == value ? Theme.mint : Theme.panel2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if processingThis {
                ProgressView()
                Text(state.status).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Button(loc.t(L.cancel)) { /* cancel hook in P5 */ }.buttonStyle(GhostButton()).disabled(true)
            } else if !state.hasKeys {
                Image(systemName: "key").font(.title).foregroundStyle(Theme.amber)
                Text(loc.t(L.needKey)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "doc.text").font(.title).foregroundStyle(Theme.muted)
                Text("—").foregroundStyle(Theme.muted)
                Button(loc.t(L.regenerate)) { state.reprocessSelected() }.buttonStyle(MintButton())
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 24) }
            .buttonStyle(GhostButton()).help(help)
    }

    private func copy() {
        guard let c = content else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
