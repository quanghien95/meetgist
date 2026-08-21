// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Export a session's notes to plain text, SRT, or JSON. (Markdown + audio are
/// the raw files already in the session folder.)
public enum Exporter {
    public enum Format: String, CaseIterable, Sendable {
        case markdown, text, srt, json
        public var ext: String {
            switch self { case .markdown: return "md"; case .text: return "txt"; case .srt: return "srt"; case .json: return "json" }
        }
        public var label: String {
            switch self { case .markdown: return "Markdown"; case .text: return "Plain text"; case .srt: return "Subtitles (SRT)"; case .json: return "JSON" }
        }
    }

    /// Render the export content as a string for a session.
    public static func render(_ format: Format, sessionDir: URL) -> String {
        let transcript = read(sessionDir, "transcript.md")
        switch format {
        case .markdown:
            return read(sessionDir, "summary.md") + "\n\n---\n\n" + read(sessionDir, "polished.md")
        case .text:
            return stripMarkdown(read(sessionDir, "summary.md") + "\n\n" + read(sessionDir, "polished.md"))
        case .srt:
            return transcriptToSRT(transcript)
        case .json:
            return toJSON(sessionDir, transcript: transcript)
        }
    }

    /// Write the export beside the session and return its URL.
    @discardableResult
    public static func write(_ format: Format, sessionDir: URL) throws -> URL {
        let name = sessionDir.lastPathComponent + "." + format.ext
        let url = sessionDir.appendingPathComponent(name)
        try render(format, sessionDir: sessionDir).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Conversions (pure)

    public static func stripMarkdown(_ md: String) -> String {
        var s = md
        for (pat, repl) in [
            (#"^#{1,6}\s*"#, ""),       // headings
            (#"\*\*([^*]+)\*\*"#, "$1"), // bold
            (#"\*([^*]+)\*"#, "$1"),     // italic
            (#"`([^`]+)`"#, "$1"),       // code
            (#"^\s*[-*]\s+"#, "• "),     // bullets
            (#"^\s*- \[[ x]\]\s*"#, "☐ "),
        ] {
            s = s.replacingOccurrences(of: pat, with: repl, options: [.regularExpression])
        }
        // line-anchored patterns need per-line application
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            l = l.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
            return l
        }
        return lines.joined(separator: "\n")
    }

    /// Parse `[MM:SS] Speaker: text` lines into SRT cues (end = next start).
    public static func transcriptToSRT(_ transcript: String) -> String {
        struct Cue { let start: Int; let speaker: String; let text: String }
        let re = try! NSRegularExpression(pattern: #"^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]\s*([^:]+):\s*(.*)$"#)
        var cues: [Cue] = []
        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let r = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = re.firstMatch(in: line, range: r) else { continue }
            func g(_ i: Int) -> String { guard let rr = Range(m.range(at: i), in: line) else { return "" }; return String(line[rr]) }
            let hasH = m.range(at: 3).location != NSNotFound
            let first = Int(g(1)) ?? 0
            let second = Int(g(2)) ?? 0
            let third = Int(g(3)) ?? 0
            let start: Int
            if hasH {
                start = first * 3600 + second * 60 + third
            } else {
                start = first * 60 + second
            }
            cues.append(Cue(start: start, speaker: g(4).trimmingCharacters(in: .whitespaces), text: g(5)))
        }
        var out = ""
        for (i, c) in cues.enumerated() {
            let end = i + 1 < cues.count ? max(cues[i + 1].start, c.start + 1) : c.start + 3
            out += "\(i + 1)\n\(srtTime(c.start)) --> \(srtTime(end))\n\(c.speaker): \(c.text)\n\n"
        }
        return out
    }

    static func srtTime(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d,000", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func toJSON(_ dir: URL, transcript: String) -> String {
        let payload: [String: Any] = [
            "title": dir.lastPathComponent,
            "transcript": transcript,
            "summary": read(dir, "summary.md"),
            "minutes": read(dir, "polished.md"),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func read(_ dir: URL, _ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}
