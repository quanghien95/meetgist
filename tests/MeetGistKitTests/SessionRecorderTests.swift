// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct SessionRecorderTests {
    /// P0-3 regression: two recordings started in the same minute with the
    /// same (or no) detected title must not collide on one session folder —
    /// the second must not reuse (and `start()` then overwrite the audio in)
    /// the first's directory. Constructing `SessionRecorder` must not start
    /// capture, so this only exercises `init`.
    @Test func secondSessionWithSameStampAndTitleGetsADisambiguatedFolder() throws {
        let output = TestSupport.makeTempDirectoryURL("meetgist-session-recorder")
        defer { try? FileManager.default.removeItem(at: output) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let first = try SessionRecorder(outputDir: output, title: "Standup")
        try Data("first-session-marker".utf8).write(to: first.sessionDir.appendingPathComponent("marker.txt"))

        let second = try SessionRecorder(outputDir: output, title: "Standup")

        #expect(first.sessionDir != second.sessionDir)
        #expect(second.sessionDir.lastPathComponent.hasPrefix(first.sessionDir.lastPathComponent + "-"))
        // The disambiguated folder still lists under its real title, not "2".
        for dir in [first.sessionDir, second.sessionDir] {
            try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.m4a"))
        }
        let listed = MeetingStore.list(in: output)
        #expect(listed.count == 2)
        #expect(listed.allSatisfy { $0.title == "Standup" })
        // The first directory (and the marker written into it) must be untouched.
        #expect(try String(contentsOf: first.sessionDir.appendingPathComponent("marker.txt"))
            == "first-session-marker")
    }

    /// The disambiguation loop itself, and confirmation that a disambiguated,
    /// no-title folder like "2026-09-26-1405-2" still parses back to the same
    /// date via `MeetingStore`'s `yyyy-MM-dd-HHmm` prefix parser (the extra
    /// "-2" component only changes the derived title, not the date).
    @Test func makeSessionDirDisambiguatesRepeatedCollisionsInOrder() throws {
        let output = TestSupport.makeTempDirectoryURL("meetgist-session-dir")
        defer { try? FileManager.default.removeItem(at: output) }

        let first = try SessionRecorder.makeSessionDir(outputDir: output, base: "2026-09-26-1405")
        let second = try SessionRecorder.makeSessionDir(outputDir: output, base: "2026-09-26-1405")
        let third = try SessionRecorder.makeSessionDir(outputDir: output, base: "2026-09-26-1405")

        #expect(first.lastPathComponent == "2026-09-26-1405")
        #expect(second.lastPathComponent == "2026-09-26-1405-2")
        #expect(third.lastPathComponent == "2026-09-26-1405-3")
        for url in [first, second, third] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // MeetingStore still recovers the correct created date from the
        // "yyyy-MM-dd-HHmm" prefix even with the "-2" disambiguation suffix.
        // Its title, however, falls back to "prettyTitle", which (for a
        // no-title folder) reads the "-2" suffix as the title — a known,
        // cosmetic side effect of disambiguation, not a date-parsing bug.
        try Data("audio".utf8).write(to: second.appendingPathComponent("mic.m4a"))
        let meeting = try #require(MeetingStore.list(in: output).first { $0.id == second.lastPathComponent })
        var expected = DateComponents()
        expected.year = 2026; expected.month = 9; expected.day = 26; expected.hour = 14; expected.minute = 5
        #expect(meeting.date == Calendar(identifier: .gregorian).date(from: expected))
        #expect(meeting.title == "2")
    }
}
