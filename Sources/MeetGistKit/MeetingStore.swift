// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// A recorded/imported session folder surfaced to the UI.
public struct Meeting: Identifiable, Sendable, Hashable {
    public let id: String        // folder name
    public let dir: URL
    public let date: Date?
    public let title: String
    public let hasTranscript: Bool
    public let hasNotes: Bool
}

/// Lists and reads session folders under the output directory.
public enum MeetingStore {
    private static let titleFile = ".meeting-title"

    public static func list(in outputDir: URL) -> [Meeting] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Meeting] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let hasAudio = fm.fileExists(atPath: url.appendingPathComponent("system.m4a").path)
                || fm.fileExists(atPath: url.appendingPathComponent("mic.m4a").path)
            let hasTranscript = fm.fileExists(atPath: url.appendingPathComponent("transcript.md").path)
            let hasMinutes = fm.fileExists(atPath: url.appendingPathComponent("polished.md").path)
            let hasSummary = fm.fileExists(atPath: url.appendingPathComponent("summary.md").path)
            let hasNotes = hasMinutes && hasSummary
            guard hasAudio || hasTranscript || hasMinutes || hasSummary else { continue }
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            out.append(Meeting(id: url.lastPathComponent, dir: url, date: date,
                               title: displayTitle(for: url), hasTranscript: hasTranscript,
                               hasNotes: hasNotes))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Read one of the markdown outputs (e.g. "transcript.md").
    public static func markdown(_ file: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// Changes only the displayed title. The session directory remains stable so
    /// transcription checkpoints and IDs do not need migration.
    public static func rename(_ meeting: Meeting, to rawTitle: String) throws {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw NSError(domain: "MeetGist.MeetingStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Meeting name cannot be empty."])
        }
        try (title + "\n").write(to: meeting.dir.appendingPathComponent(titleFile),
                                  atomically: true, encoding: .utf8)
    }

    private static func displayTitle(for dir: URL) -> String {
        if let saved = try? String(contentsOf: dir.appendingPathComponent(titleFile), encoding: .utf8) {
            let title = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return prettyTitle(dir.lastPathComponent)
    }

    /// Strip the `yyyy-MM-dd-HHmm-` prefix to a human-friendly title.
    static func prettyTitle(_ folder: String) -> String {
        let parts = folder.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count > 4 {
            let title = parts[4...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return folder
    }
}
