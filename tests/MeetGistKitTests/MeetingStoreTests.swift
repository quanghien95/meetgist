// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct MeetingStoreTests {
    @Test func meetingRenamePreservesSessionDirectoryAndTranscriptIsNotNotes() throws {
        let output = TestSupport.makeTempDirectoryURL("meetgist-meeting-store")
        defer { try? FileManager.default.removeItem(at: output) }
        let session = output.appendingPathComponent("2026-08-22-1200-Original")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("mic.m4a"))
        try Data("transcript".utf8).write(to: session.appendingPathComponent("transcript.md"))

        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate],
                                              ofItemAtPath: session.path)

        var meeting = try #require(MeetingStore.list(in: output).first)
        // The created date comes from the folder-name stamp, not the mtime,
        // so it must survive rename (which touches the directory).
        let listedDate = try #require(meeting.date)
        var expected = DateComponents()
        expected.year = 2026; expected.month = 8; expected.day = 22; expected.hour = 12; expected.minute = 0
        #expect(listedDate == Calendar(identifier: .gregorian).date(from: expected))
        #expect(meeting.title == "Original")
        #expect(meeting.hasTranscript)
        #expect(!meeting.hasNotes)
        try MeetingStore.rename(meeting, to: "Customer Review")

        meeting = try #require(MeetingStore.list(in: output).first)
        #expect(meeting.title == "Customer Review")
        // contentsOfDirectory returns symlink-resolved (/private/var) URLs.
        #expect(meeting.dir.resolvingSymlinksInPath().path == session.resolvingSymlinksInPath().path)
        #expect(meeting.id == session.lastPathComponent)
        #expect(meeting.date == listedDate)

        try Data("summary".utf8).write(to: session.appendingPathComponent("summary.md"))
        #expect(!(try #require(MeetingStore.list(in: output).first).hasNotes))
        try Data("minutes".utf8).write(to: session.appendingPathComponent("polished.md"))
        #expect(try #require(MeetingStore.list(in: output).first).hasNotes)
    }

    /// Live Assist's `<session>/live/` folder (plan §5.13) must never change
    /// listing, export, or delete behavior — `MeetingStore.list` only checks
    /// specific top-level filenames (never recurses), so an extra
    /// subdirectory full of unrelated files must be invisible to it, and
    /// `Exporter` (which reads only `transcript.md`/`summary.md`/
    /// `polished.md`) must produce identical output whether or not it
    /// exists. Deleting a meeting (`NSWorkspace.recycle` on the whole
    /// `Meeting.dir`, in `AppState.moveMeetingToTrash`) trashes this folder
    /// along with everything else — nothing extra to verify there beyond
    /// "it's a normal file under the session directory".
    @Test func liveAssistFolderDoesNotAffectListingOrExport() throws {
        let output = TestSupport.makeTempDirectoryURL("meetgist-meeting-store-live")
        defer { try? FileManager.default.removeItem(at: output) }
        let session = output.appendingPathComponent("2026-09-27-1000-Standup")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("mic.m4a"))
        try "[00:01] Speaker: hello".write(to: session.appendingPathComponent("transcript.md"),
                                          atomically: true, encoding: .utf8)
        try "Summary text".write(to: session.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "Polished text".write(to: session.appendingPathComponent("polished.md"), atomically: true, encoding: .utf8)

        let exportBefore = Exporter.render(.markdown, sessionDir: session)

        let liveDir = session.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try "{}".write(to: liveDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: liveDir.appendingPathComponent("turns.jsonl"), atomically: true, encoding: .utf8)
        try "".write(to: liveDir.appendingPathComponent("asr-worker.log"), atomically: true, encoding: .utf8)

        let listed = MeetingStore.list(in: output)
        #expect(listed.count == 1)
        let meeting = try #require(listed.first)
        #expect(meeting.title == "Standup")
        #expect(meeting.hasTranscript)
        #expect(meeting.hasNotes)

        let exportAfter = Exporter.render(.markdown, sessionDir: session)
        #expect(exportAfter == exportBefore)
    }
}
