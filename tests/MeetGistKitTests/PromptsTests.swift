// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Testing
@testable import MeetGistKit

@Suite struct PromptsTests {

    @Test func timestampFormatting() {
        #expect(Prompts.timestamp(65) == "01:05")
        #expect(Prompts.timestamp(3661) == "01:01:01")
        #expect(Prompts.timestamp(0) == "00:00")
        #expect(Prompts.timestamp(-5) == "00:00")
    }

    @Test func twoTrackPromptUsesMeAndParticipants() {
        let p = Prompts.transcript(micExists: true, systemExists: true)
        #expect(p.contains("Two synchronized audio tracks"))
        #expect(p.contains(#""Me""#))
        #expect(p.contains(#""Participant 1""#))
        #expect(!p.contains(#""Speaker 1""#))
        #expect(p.contains("---TRANSCRIPT---"))
    }

    @Test func singleTrackPromptUsesSpeakers() {
        let p = Prompts.transcript(micExists: false, systemExists: true)
        #expect(p.contains("One audio track"))
        #expect(p.contains(#""Speaker 1""#))
        #expect(!p.contains("Participant"))
    }

    @Test func segmentOffsetIsAnnotated() {
        let p = Prompts.transcript(micExists: false, systemExists: true,
                                   segmentOffsetSeconds: 65)
        #expect(p.contains("one segment of a longer recording"))
        #expect(p.contains("01:05"))
    }

    @Test func noSegmentNoteByDefault() {
        let p = Prompts.transcript(micExists: true, systemExists: true)
        #expect(!p.contains("one segment of a longer recording"))
    }

    @Test func polishedHasBothSections() {
        let p = Prompts.polished()
        #expect(p.contains("---POLISHED---"))
        #expect(p.contains("---SUMMARY---"))
        #expect(p.contains("简体中文"))
    }

    /// International meeting-minutes best practice (attendee list as an
    /// essential field, no duplicate action-item section) — see the format
    /// review this was written against.
    @Test func polishedIncludesAttendeesAndHasNoDuplicateActionItemsSection() {
        let p = Prompts.polished()
        #expect(p.contains("**Attendees**"))
        #expect(p.contains("## Action Items"))
        #expect(!p.contains("To-do Items"))
    }

    /// The "Full minutes & summary" preview in Settings is derived from
    /// `Prompts.polishedOutputFormat`, not a hand-copied duplicate — this
    /// guards against the two drifting apart again (they previously did:
    /// the preview was missing Attendees and had a stray To-do Items section
    /// that normal generation didn't produce).
    @Test func defaultTemplatePreviewMatchesPolishedOutputFormat() throws {
        let preview = try #require(NotesTemplateCatalog.builtIn.first { $0.id == "default" }).body
        #expect(preview.contains("**Attendees**"))
        #expect(preview.contains("## Action Items"))
        #expect(!preview.contains("To-do Items"))
        // Generation-only markers/instructions must not leak into what the
        // user edits as their own template.
        #expect(!preview.contains("---POLISHED---"))
        #expect(!preview.contains("---SUMMARY---"))
        #expect(!preview.contains("LANGUAGE"))
    }

    @Test func polishedDefaultsToVietnamese() {
        #expect(Prompts.defaultNotesLanguage == "Vietnamese")
        #expect(Prompts.polished().contains("Vietnamese"))
    }

    @Test func polishedUsesSuppliedLanguage() {
        let p = Prompts.polished(language: "English")
        #expect(p.contains("LANGUAGE = English"))
        #expect(!p.contains("LANGUAGE = Vietnamese"))
    }

    @Test func chineseTranscriptStillOverridesConfiguredLanguage() {
        // Even with Vietnamese configured, the LANGUAGE decision rule keeps
        // Chinese transcripts in Chinese — this must not regress.
        let p = Prompts.polished(language: "Vietnamese")
        #expect(p.contains("dominant spoken language in the transcript is Chinese"))
        #expect(p.contains("Simplified Chinese (简体中文)"))
    }

    @Test func templatedNotesUsesSuppliedLanguage() {
        let t = Prompts.templatedNotes("# My Template", language: "English")
        #expect(t.contains("Write in English"))
        #expect(t.contains("# My Template"))
    }
}
