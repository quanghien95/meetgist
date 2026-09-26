// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import XCTest
@testable import MeetGistKit

final class PromptsTests: XCTestCase {

    func testTimestampFormatting() {
        XCTAssertEqual(Prompts.timestamp(65), "01:05")
        XCTAssertEqual(Prompts.timestamp(3661), "01:01:01")
        XCTAssertEqual(Prompts.timestamp(0), "00:00")
        XCTAssertEqual(Prompts.timestamp(-5), "00:00")
    }

    func testTwoTrackPromptUsesMeAndParticipants() {
        let p = Prompts.transcript(micExists: true, systemExists: true)
        XCTAssertTrue(p.contains("Two synchronized audio tracks"))
        XCTAssertTrue(p.contains(#""Me""#))
        XCTAssertTrue(p.contains(#""Participant 1""#))
        XCTAssertFalse(p.contains(#""Speaker 1""#))
        XCTAssertTrue(p.contains("---TRANSCRIPT---"))
    }

    func testSingleTrackPromptUsesSpeakers() {
        let p = Prompts.transcript(micExists: false, systemExists: true)
        XCTAssertTrue(p.contains("One audio track"))
        XCTAssertTrue(p.contains(#""Speaker 1""#))
        XCTAssertFalse(p.contains("Participant"))
    }

    func testSegmentOffsetIsAnnotated() {
        let p = Prompts.transcript(micExists: false, systemExists: true,
                                   segmentOffsetSeconds: 65)
        XCTAssertTrue(p.contains("one segment of a longer recording"))
        XCTAssertTrue(p.contains("01:05"))
    }

    func testNoSegmentNoteByDefault() {
        let p = Prompts.transcript(micExists: true, systemExists: true)
        XCTAssertFalse(p.contains("one segment of a longer recording"))
    }

    func testPolishedHasBothSections() {
        let p = Prompts.polished()
        XCTAssertTrue(p.contains("---POLISHED---"))
        XCTAssertTrue(p.contains("---SUMMARY---"))
        XCTAssertTrue(p.contains("简体中文"))
    }

    /// International meeting-minutes best practice (attendee list as an
    /// essential field, no duplicate action-item section) — see the format
    /// review this was written against.
    func testPolishedIncludesAttendeesAndHasNoDuplicateActionItemsSection() {
        let p = Prompts.polished()
        XCTAssertTrue(p.contains("**Attendees**"))
        XCTAssertTrue(p.contains("## Action Items"))
        XCTAssertFalse(p.contains("To-do Items"))
    }

    /// The "Full minutes & summary" preview in Settings is derived from
    /// `Prompts.polishedOutputFormat`, not a hand-copied duplicate — this
    /// guards against the two drifting apart again (they previously did:
    /// the preview was missing Attendees and had a stray To-do Items section
    /// that normal generation didn't produce).
    func testDefaultTemplatePreviewMatchesPolishedOutputFormat() throws {
        let preview = try XCTUnwrap(NotesTemplateCatalog.builtIn.first { $0.id == "default" }).body
        XCTAssertTrue(preview.contains("**Attendees**"))
        XCTAssertTrue(preview.contains("## Action Items"))
        XCTAssertFalse(preview.contains("To-do Items"))
        // Generation-only markers/instructions must not leak into what the
        // user edits as their own template.
        XCTAssertFalse(preview.contains("---POLISHED---"))
        XCTAssertFalse(preview.contains("---SUMMARY---"))
        XCTAssertFalse(preview.contains("LANGUAGE"))
    }

    func testPolishedDefaultsToVietnamese() {
        XCTAssertEqual(Prompts.defaultNotesLanguage, "Vietnamese")
        XCTAssertTrue(Prompts.polished().contains("Vietnamese"))
    }

    func testPolishedUsesSuppliedLanguage() {
        let p = Prompts.polished(language: "English")
        XCTAssertTrue(p.contains("LANGUAGE = English"))
        XCTAssertFalse(p.contains("LANGUAGE = Vietnamese"))
    }

    func testChineseTranscriptStillOverridesConfiguredLanguage() {
        // Even with Vietnamese configured, the LANGUAGE decision rule keeps
        // Chinese transcripts in Chinese — this must not regress.
        let p = Prompts.polished(language: "Vietnamese")
        XCTAssertTrue(p.contains("dominant spoken language in the transcript is Chinese"))
        XCTAssertTrue(p.contains("Simplified Chinese (简体中文)"))
    }

    func testTemplatedNotesUsesSuppliedLanguage() {
        let t = Prompts.templatedNotes("# My Template", language: "English")
        XCTAssertTrue(t.contains("Write in English"))
        XCTAssertTrue(t.contains("# My Template"))
    }
}
