// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Shared, deliberately simple text-normalization used for duplicate
/// detection across `LiveTurnFilter` and `LiveMeetingState` (plan §5.7):
/// lowercase, Vietnamese-diacritic-insensitive, punctuation stripped,
/// stop-words removed, then compared by exact match / containment / token-set
/// Jaccard. No stemming, no NLP model — this only needs to catch near-
/// duplicate phrasing of the same fact, not do general semantic matching.
enum LiveTextNormalize {
    /// Small stop-word list covering the fillers/connectors most likely to
    /// differ between two paraphrases of the same point in English or
    /// Vietnamese. Not exhaustive by design.
    static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "to", "of", "in", "on",
        "and", "or", "that", "this", "it", "be", "we", "will", "should",
        "và", "là", "của", "các", "những", "một", "cần", "phải", "sẽ", "đã",
        "cái", "này", "đó", "thì", "để", "khi", "có", "không",
    ]

    /// Lowercased, diacritic-folded, alphanumeric-plus-space string with
    /// collapsed whitespace.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
            .filter { !stopWords.contains($0) }
            .map(stem)
    }

    /// A deliberately tiny suffix stripper — not a real stemmer — so common
    /// English inflections ("checked"/"checking"/"needs") land on the same
    /// token for Jaccard-based dedup. Only applied where lexical near-
    /// duplicate matching happens (`tokenSet`/`jaccard`); `appears(_:in:)`
    /// (the evidence guard's owner/deadline check) intentionally does not
    /// use this, since it must match the stated value as written.
    static func stem(_ token: String) -> String {
        guard token.count > 4 else { return token }
        for suffix in ["ing", "ed", "es"] where token.hasSuffix(suffix) && token.count - suffix.count >= 3 {
            return String(token.dropLast(suffix.count))
        }
        if token.hasSuffix("s") && !token.hasSuffix("ss") { return String(token.dropLast()) }
        return token
    }

    static func tokenSet(_ text: String) -> Set<String> { Set(tokens(text)) }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    /// True if `a` and `b` are "the same fact said differently": equal once
    /// normalized, one contains the other, or their token sets overlap at
    /// least `jaccardThreshold`.
    static func isDuplicate(_ a: String, _ b: String, jaccardThreshold: Double) -> Bool {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return na == nb }
        if na == nb || na.contains(nb) || nb.contains(na) { return true }
        return jaccard(tokenSet(a), tokenSet(b)) >= jaccardThreshold
    }

    /// True if `value` (e.g. an owner name or a deadline phrase) appears as a
    /// whole-word run inside `text` — used by the evidence guards to check a
    /// stated owner/deadline actually appears in the turns it's attributed
    /// to. Deliberately word-boundary-aware (matches on the normalized
    /// *token sequence*, not a raw substring), otherwise a short name like
    /// "An" would false-positive-match inside an unrelated word like
    /// "finance" (which contains the letters "an").
    static func appears(_ value: String, in text: String) -> Bool {
        let needleWords = normalize(value).split(separator: " ").map(String.init)
        guard !needleWords.isEmpty else { return false }
        let haystackWords = normalize(text).split(separator: " ").map(String.init)
        guard needleWords.count <= haystackWords.count else { return false }
        for start in 0...(haystackWords.count - needleWords.count) {
            if Array(haystackWords[start..<(start + needleWords.count)]) == needleWords { return true }
        }
        return false
    }
}
