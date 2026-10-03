// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI
import AppKit
import Combine
import MeetGistKit

/// Non-activating panel with optional floating behavior showing Live Assist's current understanding
/// while recording (plan §5.12). Pattern: `MiniController`. Visible only
/// while recording/paused **and** Live Assist is enabled. Finalized ASR
/// turns append to a timestamped transcript; semantic results update the
/// separate Assist tab. Neither replaces earlier transcript text.
@MainActor
final class LiveAssistPanel {
    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()
    private weak var state: AppState?
    private let loc: Localization

    init(state: AppState, loc: Localization) {
        self.state = state
        self.loc = loc
        state.$state.combineLatest(state.$liveAssistEnabled, state.$liveAssistAlwaysOnTop)
            .receive(on: RunLoop.main)
            .sink { [weak self] recState, enabled, alwaysOnTop in
                self?.update(recState, enabled, alwaysOnTop: alwaysOnTop)
            }
            .store(in: &bag)
    }

    private func update(_ recState: RecState, _ enabled: Bool, alwaysOnTop: Bool) {
        let show = enabled && (recState == .recording || recState == .paused)
        show ? present() : dismiss()
        panel?.isFloatingPanel = alwaysOnTop
        panel?.level = alwaysOnTop ? .floating : .normal
    }

    private func present() {
        guard let state else { return }
        if panel == nil {
            let visibleFrame = NSScreen.main?.visibleFrame
            let size = NSSize(width: min(640, (visibleFrame?.width ?? 680) - 40),
                              height: min(720, (visibleFrame?.height ?? 760) - 40))
            let view = NSHostingView(rootView: LiveAssistPanelView().environmentObject(state).environmentObject(loc)
                .preferredColorScheme(.dark))
            // The window owns its size; a new snapshot must not resize it
            // to the SwiftUI content's intrinsic height.
            view.sizingOptions = [.minSize]
            view.autoresizingMask = [.width, .height]
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = loc.t(L.liveAssist)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.isFloatingPanel = state.liveAssistAlwaysOnTop
            panel.level = state.liveAssistAlwaysOnTop ? .floating : .normal
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            panel.setContentSize(size)
            panel.contentMinSize = NSSize(width: 440, height: 360)
            if let f = visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 20))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    private func dismiss() { panel?.orderOut(nil) }
}

private struct LiveAssistPanelView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var loc: Localization
    var body: some View {
        LiveAssistPanelContent(state: state, liveAssist: state.liveAssist, loc: loc)
    }
}

private struct LiveAssistPanelContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveAssist: LiveAssistState
    let loc: Localization
    @CompatibleState private var collapsed = false
    @CompatibleState private var askText = ""
    @CompatibleState private var showingTranscript = true

    private var notesLanguage: String { state.notesLanguage }

    var body: some View {
        let snapshot = liveAssist.snapshot
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
                .padding(16)
            RecordingControllerView(embedded: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            if !collapsed {
                if let error = snapshot.micCaptureError {
                    Text(loc.t(L.liveMicUnavailable))
                        .font(Theme.ui(12)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                Picker(loc.t(L.language), selection: $state.liveTranscriptionLanguage) {
                    Text(loc.t(L.langEnglish)).tag("en")
                    Text(loc.t(L.langAuto)).tag("auto")
                    Text(loc.t(L.langVietnamese)).tag("vi")
                    Text(loc.t(L.langChinese)).tag("zh")
                    Text(loc.t(L.langSpanish)).tag("es")
                    Text(loc.t(L.langFrench)).tag("fr")
                    Text(loc.t(L.langGerman)).tag("de")
                    Text(loc.t(L.langJapanese)).tag("ja")
                    Text(loc.t(L.langKorean)).tag("ko")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                Picker(loc.t(L.liveAssist), selection: $showingTranscript) {
                    Text(loc.t(L.transcript)).tag(true)
                    Text(loc.t(L.liveAssist)).tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            Group {
                                if showingTranscript {
                                    VStack(alignment: .leading, spacing: 0) {
                                        transcriptSection(snapshot)
                                        Color.clear.frame(height: 1).id("live-transcript-bottom")
                                        Color.clear.frame(height: viewport.size.height / 2)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 14) {
                                        meaningSection(snapshot)
                                        questionSection(snapshot)
                                        if hasActiveQuestion(snapshot) { suggestAnswerRow(snapshot) }
                                        if hasNotes(snapshot) { notesSection(snapshot) }
                                        if snapshot.v2AnswerInFlight || snapshot.v2Answer != nil || snapshot.v2Error != nil {
                                            answerSection(snapshot)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                            .textSelection(.enabled)
                        }
                        .onAppear { if showingTranscript { proxy.scrollTo("live-transcript-bottom", anchor: .center) } }
                        .onChange(of: snapshot.latestTranscriptTurn?.id) { _, _ in
                            if showingTranscript { proxy.scrollTo("live-transcript-bottom", anchor: .center) }
                        }
                        .onChange(of: showingTranscript) { _, transcript in
                            if transcript { proxy.scrollTo("live-transcript-bottom", anchor: .center) }
                        }
                    }
                }
                if !showingTranscript {
                    Divider()
                    askMeetGistSection
                        .padding(16)
                }
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel.opacity(0.97))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: snapshot.latestTranscriptTurn?.id) { _, newID in
            if let newID { state.stampLiveUIUpdate(turnID: newID) }
        }
    }

    private func header(_ snapshot: LiveAssistSnapshot) -> some View {
        HStack {
            Text(loc.t(L.liveAssist).uppercased())
                .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.muted)
            Spacer()
            Toggle(loc.t(L.liveAlwaysOnTop), isOn: $state.liveAssistAlwaysOnTop)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(Theme.ui(11))
            StatusPill(color: state.state == .paused ? Theme.amber : statusColor(snapshot.status),
                       text: state.state == .paused ? loc.t(L.paused) : statusText(snapshot.status, loc),
                       pulse: state.state != .paused && snapshot.status == .analyzing)
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
    }

    private func meaningSection(_ snapshot: LiveAssistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LiveAssistLabels.theyMean(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
            if let meaning = snapshot.lastMeaning, !meaning.isEmpty {
                Text(meaning).font(Theme.ui(13)).foregroundStyle(Theme.text)
            } else {
                Text(loc.t(L.liveAssistWaitingForSpeech)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func questionSection(_ snapshot: LiveAssistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LiveAssistLabels.theyAsk(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
            if let question = snapshot.lastQuestion, !question.isEmpty, snapshot.openQuestionCount > 0 {
                Text(question).font(Theme.ui(13)).foregroundStyle(Theme.text)
            } else {
                Text(LiveAssistLabels.noActiveQuestion(notesLanguage)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func hasNotes(_ snapshot: LiveAssistSnapshot) -> Bool {
        !snapshot.keyPoints.isEmpty || !snapshot.decisions.isEmpty || !snapshot.actionItems.isEmpty
    }

    // MARK: - V2: Suggested Answer (plan §7.1)

    private func hasActiveQuestion(_ snapshot: LiveAssistSnapshot) -> Bool {
        snapshot.lastQuestion != nil && !(snapshot.lastQuestion ?? "").isEmpty && snapshot.openQuestionCount > 0
    }

    private func suggestAnswerRow(_ snapshot: LiveAssistSnapshot) -> some View {
        Button {
            state.suggestAnswer()
        } label: {
            HStack(spacing: 6) {
                if snapshot.v2AnswerInFlight { ProgressView().controlSize(.small) }
                Text(LiveAssistLabels.suggestAnswerButton(notesLanguage))
            }
        }
        .buttonStyle(.bordered)
        .disabled(snapshot.v2AnswerInFlight)
    }

    /// Shows whichever V2 result ran most recently (Suggest Answer or Ask):
    /// an in-progress state first (user priority — Codex CLI is ~7s p50,
    /// never leave this looking stuck with no feedback), then the answer
    /// with its "known"/"from context"/"assumptions" lines, or an error.
    private func answerSection(_ snapshot: LiveAssistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.v2AnswerInFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(LiveAssistLabels.generatingAnswer(notesLanguage)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
            } else if let answer = snapshot.v2Answer {
                Text(answer.answer).font(Theme.ui(13)).foregroundStyle(Theme.text)
                if !answer.knownFromMeeting.isEmpty {
                    evidenceLines(title: LiveAssistLabels.knownFromMeeting(notesLanguage), items: answer.knownFromMeeting, color: Theme.mint)
                }
                if !answer.fromContext.isEmpty {
                    evidenceLines(title: LiveAssistLabels.fromContext(notesLanguage), items: answer.fromContext, color: Theme.mint)
                }
                if !answer.assumptions.isEmpty {
                    evidenceLines(title: LiveAssistLabels.assumptions(notesLanguage), items: answer.assumptions, color: Theme.amber)
                }
            } else if let error = snapshot.v2Error {
                Text(error).font(Theme.ui(12)).foregroundStyle(Theme.amber)
            }
        }
    }

    private func evidenceLines(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.mono(9, .semibold)).foregroundStyle(color)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("· \(item)").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - V2: Ask Meet Gist (plan §7.2/§7.3)

    private var askMeetGistSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LiveAssistLabels.askMeetGistTitle(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                TextField(LiveAssistLabels.askMeetGistPlaceholder(notesLanguage), text: $askText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.ui(12))
                    .onSubmit(submitAsk)
                Button(action: submitAsk) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            contextRow
        }
    }

    private var contextRow: some View {
        HStack(spacing: 6) {
            if let provider = liveAssist.contextProvider {
                Text("\(loc.t(L.liveContextLabel)): \(provider.fileName)")
                    .font(Theme.mono(9)).foregroundStyle(Theme.muted).lineLimit(1)
                if provider.truncated {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundStyle(Theme.amber)
                        .help(LiveAssistLabels.contextTruncatedNote(notesLanguage))
                }
                Button(loc.t(L.liveContextClearButton)) { state.clearLiveContextFile() }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.muted)
            } else {
                Text(LiveAssistLabels.contextNone(notesLanguage)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                Button(loc.t(L.liveContextChooseButton)) { state.pickLiveContextFile() }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.mint)
            }
        }
    }

    private func submitAsk() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        state.askMeetGist(question)
        askText = ""
    }

    private func notesSection(_ snapshot: LiveAssistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LiveAssistLabels.liveNotes(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
            ForEach(Array(snapshot.keyPoints.enumerated()), id: \.offset) { _, point in
                Text("• \(point)").font(Theme.ui(12)).foregroundStyle(Theme.text)
            }
            if !snapshot.decisions.isEmpty {
                Text(LiveAssistLabels.decisions(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
                ForEach(Array(snapshot.decisions.enumerated()), id: \.offset) { _, decision in
                    Text("✓ \(decision)").font(Theme.ui(12)).foregroundStyle(Theme.mint)
                }
            }
            if !snapshot.actionItems.isEmpty {
                Text(LiveAssistLabels.actionItems(notesLanguage)).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.muted)
                ForEach(Array(snapshot.actionItems.enumerated()), id: \.offset) { _, item in
                    Text("▸ \(item.text)\(item.owner.map { " — \($0)" } ?? "")")
                        .font(Theme.ui(12)).foregroundStyle(Theme.text)
                }
            }
        }
    }

    private func transcriptSection(_ snapshot: LiveAssistSnapshot) -> some View {
        // Preserve source compatibility for snapshots constructed by callers
        // that still provide only the latest turn.
        let turns = snapshot.transcriptTurns.isEmpty
            ? snapshot.latestTranscriptTurn.map { [$0] } ?? [] : snapshot.transcriptTurns
        return LazyVStack(alignment: .leading, spacing: 16) {
            if turns.isEmpty {
                Text(loc.t(L.liveAssistWaitingForSpeech)).font(Theme.ui(13)).foregroundStyle(Theme.muted)
            }
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(TimerLabel.fmt(max(0, turn.startedAt)))–\(TimerLabel.fmt(max(0, turn.endedAt)))")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        Text(turn.track == .speaker ? loc.t(L.system) : loc.t(L.me))
                            .font(Theme.ui(11, .semibold))
                            .foregroundStyle(turn.track == .speaker ? Theme.teal : Theme.mint)
                    }
                    Text(turn.text).font(Theme.ui(14)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusColor(_ status: LiveAssistSnapshot.Status) -> Color {
        switch status {
        case .listening, .analyzing: return Theme.mint
        case .idle: return Theme.muted
        case .malformedResponse: return Theme.muted
        case .providerUnavailableRetrying, .codexUnavailable, .liveTranscriptionUnavailable,
             .chooseCloudProvider, .liveASRNotInstalled:
            return Theme.amber
        }
    }

    private func statusText(_ status: LiveAssistSnapshot.Status, _ loc: Localization) -> String {
        switch status {
        case .idle: return loc.t(L.liveStatusIdle)
        case .listening: return loc.t(L.liveStatusListening)
        case .analyzing: return loc.t(L.liveStatusAnalyzing)
        case .malformedResponse: return loc.t(L.liveStatusMalformed)
        case .providerUnavailableRetrying: return loc.t(L.liveStatusProviderRetrying)
        case .codexUnavailable: return loc.t(L.liveStatusCodexUnavailable)
        case .liveTranscriptionUnavailable: return loc.t(L.liveStatusASRUnavailable)
        case .chooseCloudProvider: return loc.t(L.liveStatusChooseProvider)
        case .liveASRNotInstalled: return loc.t(L.liveStatusASRNotInstalled)
        }
    }
}
