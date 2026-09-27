// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Minimal block-level Markdown for the notes the providers write (headings,
/// bullets, task items, numbered items, fenced code, paragraphs). SwiftUI's
/// `Text(AttributedString(markdown:))` only renders inline styling and would
/// show `## Heading` / `- [ ] task` literally, so blocks are parsed here and
/// inline spans (bold, italic, code, links) still go through AttributedString.
enum MarkdownBlock: Sendable {
    case heading(level: Int, text: AttributedString)
    case bullet(indent: Int, text: AttributedString)
    case task(indent: Int, done: Bool, text: AttributedString)
    case numbered(indent: Int, marker: String, text: AttributedString)
    case code(String)
    case paragraph(AttributedString)
    case spacer

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var fence: [String]?
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = fence { blocks.append(.code(lines.joined(separator: "\n"))); fence = nil }
                else { fence = [] }
                continue
            }
            if fence != nil { fence?.append(raw); continue }
            if trimmed.isEmpty {
                if case .spacer? = blocks.last {} else if !blocks.isEmpty { blocks.append(.spacer) }
                continue
            }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
               trimmed[hashes] == " " {
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level: min(level, 4), text: inline(String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces))))
                continue
            }
            for prefix in ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "* [x] "] where trimmed.hasPrefix(prefix) {
                blocks.append(.task(indent: indent, done: !prefix.contains("[ ]"),
                                    text: inline(String(trimmed.dropFirst(prefix.count)))))
                break
            }
            if case .task? = blocks.last, trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") { continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                blocks.append(.bullet(indent: indent, text: inline(String(trimmed.dropFirst(2)))))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber),
               !trimmed[..<dot].isEmpty, trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.numbered(indent: indent, marker: String(trimmed[...dot]),
                                        text: inline(String(trimmed[trimmed.index(dot, offsetBy: 2)...]))))
                continue
            }
            if trimmed == "---" || trimmed == "***" { blocks.append(.spacer); continue }
            blocks.append(.paragraph(inline(trimmed)))
        }
        if let lines = fence { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(block).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Theme.ui(level <= 1 ? 18 : level == 2 ? 15 : 13, .semibold))
                .foregroundStyle(level <= 2 ? Theme.text : Theme.muted)
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let indent, let text):
            marker("•", indent: indent, color: Theme.mint) { Text(text) }
        case .task(let indent, let done, let text):
            marker(done ? "☑" : "☐", indent: indent, color: done ? Theme.mint : Theme.muted) {
                Text(text).strikethrough(done, color: Theme.muted)
            }
        case .numbered(let indent, let number, let text):
            marker(number, indent: indent, color: Theme.muted, mono: true) { Text(text) }
        case .code(let code):
            Text(code).font(Theme.mono(11)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).panel(Theme.panel)
        case .paragraph(let text):
            Text(text).font(Theme.ui(13)).foregroundStyle(Theme.text).lineSpacing(2)
        case .spacer:
            Color.clear.frame(height: 4)
        }
    }

    private func marker<Content: View>(_ glyph: String, indent: Int, color: Color, mono: Bool = false,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(glyph).font(mono ? Theme.mono(12) : Theme.ui(13)).foregroundStyle(color)
                .frame(minWidth: 12, alignment: .leading)
            content().font(Theme.ui(13)).foregroundStyle(Theme.text).lineSpacing(2)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }
}

/// One `[MM:SS] Speaker: text` transcript line: the timestamp reads as a mono
/// instrument readout and the speaker is set apart from what they said.
struct TranscriptLineView: View {
    let line: String

    var body: some View {
        let parsed = Self.split(line)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let stamp = parsed.stamp {
                Text(stamp).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .frame(minWidth: 44, alignment: .leading)
            }
            // "Me" is the mic track (mint, like its track dot); everyone else
            // came through system audio (teal).
            (parsed.speaker.map {
                Text("\($0): ").foregroundColor($0 == "Me" ? Theme.mint : Theme.teal).fontWeight(.medium)
            } ?? Text(""))
                + Text(parsed.text).foregroundColor(Theme.text)
        }
        .font(Theme.ui(13))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func split(_ line: String) -> (stamp: String?, speaker: String?, text: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return (nil, nil, line) }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        guard stamp.allSatisfy({ $0.isNumber || $0 == ":" }), stamp.contains(":") else { return (nil, nil, line) }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 32 {
            let speaker = String(rest[..<colon])
            let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (stamp, speaker, text)
        }
        return (stamp, nil, rest)
    }
}
