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
}
