// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct LiveCopilotTurnFilterTests {
    private func turn(_ id: Int, _ track: LiveTrack, _ text: String, start: Double, end: Double) -> LiveTranscriptTurn {
        LiveTranscriptTurn(id: id, track: track, startedAt: start, endedAt: end, text: text)
    }

    @Test func emptyOrWhitespaceIsDropped() {
        let filter = LiveTurnFilter()
        let t = turn(1, .speaker, "   \n  ", start: 0, end: 2)
        #expect(filter.shouldDrop(t, recentSameTrack: [], recentOtherTrack: []))
    }

    @Test func shortAndQuickUtteranceIsDropped() {
        let filter = LiveTurnFilter()
        let t = turn(1, .speaker, "ok", start: 0, end: 0.3)
        #expect(filter.shouldDrop(t, recentSameTrack: [], recentOtherTrack: []))
    }

    @Test func shortButLongEnoughUtteranceIsKept() {
        let filter = LiveTurnFilter()
        // 1 word but long duration (e.g. drawn-out speech) survives the
        // combined word-count/duration rule.
        let t = turn(1, .speaker, "Absolutely", start: 0, end: 1.2)
        #expect(!filter.shouldDrop(t, recentSameTrack: [], recentOtherTrack: []))
    }

    @Test func fillerWordsAreDropped() {
        let filter = LiveTurnFilter()
        for filler in ["ừ", "vâng dạ", "okay yeah", "mm"] {
            let t = turn(1, .speaker, filler, start: 0, end: 1.0)
            #expect(filter.shouldDrop(t, recentSameTrack: [], recentOtherTrack: []), "expected '\(filler)' to be filtered")
        }
    }

    @Test func realSentenceContainingAFillerWordIsNotDropped() {
        let filter = LiveTurnFilter()
        let t = turn(1, .speaker, "ok vậy mình chốt phương án này nhé", start: 0, end: 2.0)
        #expect(!filter.shouldDrop(t, recentSameTrack: [], recentOtherTrack: []))
    }

    @Test func duplicateOfRecentSameTrackTurnIsDropped() {
        let filter = LiveTurnFilter()
        let previous = turn(1, .speaker, "We need to check the ERP integration", start: 0, end: 2)
        let duplicate = turn(2, .speaker, "We need to check the ERP integration", start: 3, end: 5)
        #expect(filter.shouldDrop(duplicate, recentSameTrack: [previous], recentOtherTrack: []))
    }

    @Test func distinctSameTrackTurnIsKept() {
        let filter = LiveTurnFilter()
        let previous = turn(1, .speaker, "We need to check the ERP integration", start: 0, end: 2)
        let distinct = turn(2, .speaker, "Let's talk about the marketing budget next quarter", start: 3, end: 6)
        #expect(!filter.shouldDrop(distinct, recentSameTrack: [previous], recentOtherTrack: []))
    }

    @Test func micTurnOverlappingSpeakerTurnIsTreatedAsEcho() {
        let filter = LiveTurnFilter()
        let speakerTurn = turn(1, .speaker, "the deadline is next Friday for sure", start: 10.0, end: 12.0)
        let micEcho = turn(2, .me, "the deadline is next Friday for sure", start: 10.2, end: 12.1)
        #expect(filter.shouldDrop(micEcho, recentSameTrack: [], recentOtherTrack: [speakerTurn]))
    }

    @Test func micTurnFarFromAnySpeakerOverlapIsNotTreatedAsEcho() {
        let filter = LiveTurnFilter()
        let speakerTurn = turn(1, .speaker, "the deadline is next Friday for sure", start: 10.0, end: 12.0)
        let micTurn = turn(2, .me, "actually I think we should push it back a week", start: 60.0, end: 63.0)
        #expect(!filter.shouldDrop(micTurn, recentSameTrack: [], recentOtherTrack: [speakerTurn]))
    }
}
