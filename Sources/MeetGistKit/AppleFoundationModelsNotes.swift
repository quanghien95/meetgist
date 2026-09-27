// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleFoundationModelsAvailability: Equatable, Sendable {
    case ready
    case requiresMacOS26
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable
    case frameworkUnavailable

    public var isReady: Bool { self == .ready }

    public var message: String {
        switch self {
        case .ready:
            return "Ready · processing stays on this Mac."
        case .requiresMacOS26:
            return "Requires macOS 26 or later."
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings."
        case .modelNotReady:
            return "The Apple Intelligence model is not ready yet; it may still be downloading."
        case .unavailable:
            return "Apple On-Device is currently unavailable."
        case .frameworkUnavailable:
            return "This MeetGist build does not include Foundation Models support."
        }
    }
}

public enum AppleFoundationModelsSupport {
    public static var availability: AppleFoundationModelsAvailability {
        guard #available(macOS 26.0, *) else { return .requiresMacOS26 }
#if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
#else
        return .frameworkUnavailable
#endif
    }
}

/// The single Apple-specific test boundary. It prevents tests from requiring an
/// Apple Intelligence model without introducing a generic local-LLM layer.
protocol AppleFoundationModelsGenerating: Sendable {
    func generate(instructions: String, prompt: String) async throws -> String
}

private struct AppleSystemModelGenerator: AppleFoundationModelsGenerating {
    func generate(instructions: String, prompt: String) async throws -> String {
        let availability = AppleFoundationModelsSupport.availability
        guard availability.isReady else {
            throw PipelineError.unsupported(availability.message)
        }
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw PipelineError.badResponse("empty Apple On-Device output") }
            return output
        }
#endif
        throw PipelineError.unsupported(availability.message)
    }
}

struct AppleFoundationModelsNotesWriter: NotesWriter {
    let template: String?
    let language: String
    private let generator: any AppleFoundationModelsGenerating
    var label: String { "Apple On-Device" }

    /// The on-device model has a small, shared input/output context window. Keep
    /// source batches conservative so instructions and the generated response have
    /// room in the same session. Character limits are intentionally stricter than
    /// token estimates for Vietnamese/CJK text, where one character can be a token.
    static let sourceChunkCharacters = 1_600
    static let finalSourceCharacters = 900

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage) {
        self.template = template
        self.language = language
        self.generator = AppleSystemModelGenerator()
    }

    init(template: String? = nil, language: String = Prompts.defaultNotesLanguage,
         generator: any AppleFoundationModelsGenerating) {
        self.template = template
        self.language = language
        self.generator = generator
    }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        progress("Writing minutes & summary on-device…")
        let source: String
        if transcript.count <= Self.finalSourceCharacters {
            source = transcript
        } else {
            source = try await condensedSource(from: transcript, progress: progress)
        }
        try Task.checkCancellation()
        if let template, !template.isEmpty {
            let output = try await generator.generate(
                instructions: Prompts.templatedNotes(template, language: language),
                prompt: source)
            return (output, output)
        }
        let raw = try await generator.generate(
            instructions: Prompts.polished(language: language),
            prompt: source)
        return splitPolished(raw)
    }

    /// Extract faithful, compact facts from independent transcript chunks, then
    /// recursively reduce them until the final notes prompt fits a fresh session.
    /// Every generator call creates a new LanguageModelSession, so no previous
    /// prompt/output consumes the next call's context window.
    private func condensedSource(
        from transcript: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let chunks = Self.splitForContext(transcript, limit: Self.sourceChunkCharacters)
        var summaries: [String] = []
        summaries.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress("Analyzing transcript chunk \(index + 1) of \(chunks.count)…")
            let summary = try await generator.generate(
                instructions: Self.chunkExtractionInstructions,
                prompt: chunk)
            if !summary.isEmpty { summaries.append(summary) }
        }

        var combined = summaries.joined(separator: "\n\n")
        var pass = 1
        while combined.count > Self.finalSourceCharacters {
            let batches = Self.splitForContext(combined, limit: Self.sourceChunkCharacters)
            var reduced: [String] = []
            reduced.reserveCapacity(batches.count)
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                progress("Condensing notes pass \(pass), batch \(index + 1) of \(batches.count)…")
                let summary = try await generator.generate(
                    instructions: Self.reductionInstructions,
                    prompt: batch)
                if !summary.isEmpty { reduced.append(summary) }
            }
            let next = reduced.joined(separator: "\n\n")
            guard !next.isEmpty else {
                throw PipelineError.badResponse("empty Apple On-Device chunk summary")
            }
            // A model may ignore the requested output limit. Fail explicitly
            // rather than loop forever or silently discard later meeting facts.
            if next.count >= combined.count {
                throw PipelineError.badResponse(
                    "Apple On-Device could not condense the transcript within its context limit")
            }
            combined = next
            pass += 1
        }
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.badResponse("empty Apple On-Device chunk summary")
        }
        return combined
    }

    /// Prefer transcript line boundaries, but split oversized individual lines so
    /// malformed or imported transcripts cannot exceed the context-safe limit.
    static func splitForContext(_ text: String, limit: Int) -> [String] {
        guard limit > 0, text.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var current = ""

        func flushCurrent() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            while line.count > limit {
                flushCurrent()
                let end = line.index(line.startIndex, offsetBy: limit)
                result.append(String(line[..<end]))
                line = String(line[end...])
            }
            let addition = current.isEmpty ? line : "\n" + line
            if current.count + addition.count > limit { flushCurrent() }
            current += current.isEmpty ? line : "\n" + line
        }
        flushCurrent()
        return result
    }

    /// Intermediate extraction/reduction steps deliberately keep the
    /// transcript's own source language rather than translating early: only
    /// the final `notes()` call (via `Prompts.polished(language:)`) translates
    /// into the configured output language, so multi-pass condensation never
    /// compounds translation drift across chunks.
    private static let chunkExtractionInstructions = """
    Extract a compact, factual record from this part of a meeting transcript.
    Preserve timestamps, speakers, decisions, action items, owners, deadlines,
    risks, open questions, and important technical details. Do not invent facts.
    Write in the transcript's dominant source language (do not translate yet).
    Output only concise bullet points, no preamble, and keep the response under
    900 characters.
    """

    private static let reductionInstructions = """
    Condense these partial meeting facts without losing decisions, action items,
    owners, deadlines, risks, open questions, timestamps, or technical details.
    Merge duplicates and do not invent facts. Keep the dominant source language
    (do not translate yet). Output only concise bullet points, no preamble,
    under 900 characters.
    """
}
