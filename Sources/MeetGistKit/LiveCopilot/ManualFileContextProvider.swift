// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// V2's manual project context (plan §7.3): the user picks one `.md`/`.txt`
/// file per meeting (via `NSOpenPanel`, app-side); this type reads it once,
/// caps it, and implements the `LiveContextProvider` seam so `Suggest
/// Answer`/`Ask Meet Gist` call sites never need to know whether their
/// context came from a manually picked file (V2, this type) or a future V3
/// retrieval provider (plan §12) — the seam is what makes that swap
/// possible without touching `LiveCopilotEngine`.
///
/// In memory only: nothing here writes the file's content to disk.
/// `LiveCopilotPersistence.appendAssist` logs only `fileName`, never `text`
/// (plan §7.3/§13's persistence-line-shape requirement).
public struct ManualFileContextProvider: LiveContextProvider, Sendable, Equatable {
    /// ≈24k chars (plan §7.3). Kept as a static default rather than a magic
    /// number at each call site; callers needing a different cap (tests) can
    /// still override it.
    public static let defaultMaxChars = 24_000

    public let fileName: String
    public let text: String
    /// True when the source file was longer than `maxChars` and had to be
    /// cut — the UI shows a "truncated" note right after the user picks the
    /// file (plan §7.3: "cap size (≈ 24k chars, warn when cut)").
    public let truncated: Bool

    public init(fileURL: URL, maxChars: Int = ManualFileContextProvider.defaultMaxChars) throws {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        try self.init(fileName: fileURL.lastPathComponent, rawText: raw, maxChars: maxChars)
    }

    /// Test/seam-friendly initializer that doesn't touch the filesystem.
    public init(fileName: String, rawText: String, maxChars: Int = ManualFileContextProvider.defaultMaxChars) throws {
        guard maxChars > 0 else { throw PipelineError.unsupported("Context file size cap must be positive.") }
        self.fileName = fileName
        if exceedsCap(rawText, maxChars) {
            self.text = String(rawText.prefix(maxChars))
            self.truncated = true
        } else {
            self.text = rawText
            self.truncated = false
        }
    }

    /// One snippet, the whole (already-capped) file content — no chunking,
    /// no retrieval, no ranking (plan §7.3: "No embeddings, no indexing, no
    /// vector DB"). `question` is accepted only to satisfy the
    /// `LiveContextProvider` protocol; this V2 implementation always returns
    /// everything it has regardless of the question asked.
    public func snippets(forQuestion question: String) async throws -> [ContextSnippet] {
        [ContextSnippet(source: fileName, text: text)]
    }
}

/// `String.count` walks the whole string (grapheme clusters) — cheap enough
/// here since this only ever runs once per manually picked file, but kept as
/// a tiny named helper so the intent ("did we exceed the cap") reads clearly
/// at the call site above.
private func exceedsCap(_ text: String, _ maxChars: Int) -> Bool {
    text.count > maxChars
}
