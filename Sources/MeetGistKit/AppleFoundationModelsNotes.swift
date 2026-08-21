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
    private let generator: any AppleFoundationModelsGenerating
    var label: String { "Apple On-Device" }

    init(template: String? = nil) {
        self.template = template
        self.generator = AppleSystemModelGenerator()
    }

    init(template: String? = nil, generator: any AppleFoundationModelsGenerating) {
        self.template = template
        self.generator = generator
    }

    func notes(transcript: String,
               progress: @escaping @Sendable (String) -> Void) async throws
        -> (polished: String, summary: String) {
        progress("Writing minutes & summary on-device…")
        if let template, !template.isEmpty {
            let output = try await generator.generate(
                instructions: Prompts.templatedNotes(template) + Self.languageRule,
                prompt: transcript)
            return (output, output)
        }
        let raw = try await generator.generate(
            instructions: Prompts.polished + Self.languageRule,
            prompt: transcript)
        return splitPolished(raw)
    }

    private static let languageRule = """

    Additional language rule for this on-device provider: if Vietnamese is the
    dominant language, write the entire response and headings in natural Vietnamese
    while preserving English technical terms. Use only facts present in the
    transcript; never invent owners, deadlines, decisions, risks, or blockers.
    """
}
