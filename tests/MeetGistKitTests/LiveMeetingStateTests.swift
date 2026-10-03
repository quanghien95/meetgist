// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

@Suite struct LiveMeetingStateTests {
    private func turn(_ id: Int, _ text: String, track: LiveTrack = .speaker) -> LiveTranscriptTurn {
        LiveTranscriptTurn(id: id, track: track, startedAt: Double(id), endedAt: Double(id) + 1, text: text)
    }

    @Test func addsANewKeyPoint() {
        var state = LiveMeetingState()
        let result = SemanticResult(meaning: "m", keyPoints: ["ERP must be checked before go-live"])
        state.apply(result, forTurns: [turn(1, "We need to check ERP before go-live")])
        #expect(state.keyPoints.count == 1)
        #expect(state.keyPoints.first?.text == "ERP must be checked before go-live")
    }

    @Test func nearDuplicateKeyPointsAreMergedNotDuplicated() {
        var state = LiveMeetingState()
        let t = [turn(1, "ERP integration check")]
        // Three paraphrases of the same fact — same content words in
        // different order/inflection/wrapping should merge into one entry
        // under the plan's "token-set Jaccard ≥ 0.6 or containment" rule.
        state.apply(SemanticResult(meaning: "m", keyPoints: ["ERP integration check is needed"]), forTurns: t)
        state.apply(SemanticResult(meaning: "m", keyPoints: ["We need to check the ERP integration"]), forTurns: t)
        state.apply(SemanticResult(meaning: "m", keyPoints: ["Check the ERP integration"]), forTurns: t)
        #expect(state.keyPoints.count == 1, "expected paraphrases of the same fact to merge, got \(state.keyPoints.map(\.text))")
    }

    @Test func distinctKeyPointsAreBothKept() {
        var state = LiveMeetingState()
        let t = [turn(1, "x")]
        state.apply(SemanticResult(meaning: "m", keyPoints: ["Budget was approved for Q3"]), forTurns: t)
        state.apply(SemanticResult(meaning: "m", keyPoints: ["The office is moving to a new building"]), forTurns: t)
        #expect(state.keyPoints.count == 2)
    }

    @Test func explicitDecisionWithEvidenceIsKept() {
        var state = LiveMeetingState()
        let turns = [turn(1, "Let's go ahead and ship v2 next sprint, everyone agreed.")]
        let result = SemanticResult(meaning: "m", decisions: [
            SemanticDecision(text: "Ship v2 next sprint", evidence: "ship v2 next sprint"),
        ])
        state.apply(result, forTurns: turns)
        #expect(state.decisions.count == 1)
        #expect(state.decisions.first?.text == "Ship v2 next sprint")
    }

    @Test func decisionWithoutSupportingEvidenceIsDropped() {
        var state = LiveMeetingState()
        let turns = [turn(1, "We might look into this at some point.")]
        let result = SemanticResult(meaning: "m", decisions: [
            SemanticDecision(text: "We will acquire our competitor", evidence: "we will acquire our competitor next week"),
        ])
        state.apply(result, forTurns: turns)
        #expect(state.decisions.isEmpty, "a decision must never be invented from unsupported evidence")
    }

    @Test func actionItemWithEvidenceIsKept() {
        var state = LiveMeetingState()
        let turns = [turn(1, "An will follow up with finance by Friday.")]
        let result = SemanticResult(meaning: "m", actionItems: [
            SemanticActionItem(text: "Follow up with finance", owner: "An", deadline: "Friday",
                              evidence: "An will follow up with finance by Friday"),
        ])
        state.apply(result, forTurns: turns)
        #expect(state.actionItems.count == 1)
        #expect(state.actionItems.first?.owner == "An")
        #expect(state.actionItems.first?.deadline == "Friday")
    }

    @Test func invalidInventedOwnerIsRemovedButActionItemSurvives() {
        var state = LiveMeetingState()
        let turns = [turn(1, "Someone needs to follow up with finance by Friday.")]
        let result = SemanticResult(meaning: "m", actionItems: [
            SemanticActionItem(text: "Follow up with finance", owner: "An", deadline: "Friday",
                              evidence: "follow up with finance by Friday"),
        ])
        state.apply(result, forTurns: turns)
        #expect(state.actionItems.count == 1)
        #expect(state.actionItems.first?.owner == nil, "owner 'An' never appears in the turns and must not be invented")
        #expect(state.actionItems.first?.deadline == "Friday")
    }

    @Test func invalidInventedDeadlineIsRemoved() {
        var state = LiveMeetingState()
        let turns = [turn(1, "An will follow up with finance soon.")]
        let result = SemanticResult(meaning: "m", actionItems: [
            SemanticActionItem(text: "Follow up with finance", owner: "An", deadline: "next Tuesday",
                              evidence: "An will follow up with finance soon"),
        ])
        state.apply(result, forTurns: turns)
        #expect(state.actionItems.first?.owner == "An")
        #expect(state.actionItems.first?.deadline == nil)
    }

    @Test func unresolvedOpenQuestionStaysOpen() {
        var state = LiveMeetingState()
        state.apply(SemanticResult(meaning: "m", openQuestions: ["Who owns the ERP migration?"]), forTurns: [turn(1, "x")])
        #expect(state.openQuestions.count == 1)
        #expect(state.openQuestions.first?.isOpen == true)
    }

    @Test func resolvedOpenQuestionIDClosesIt() {
        var state = LiveMeetingState()
        state.apply(SemanticResult(meaning: "m", openQuestions: ["Who owns the ERP migration?"]), forTurns: [turn(1, "x")])
        let id = try! #require(state.openQuestions.first?.id)
        state.apply(SemanticResult(meaning: "m", resolvedOpenQuestionIDs: [id]), forTurns: [turn(2, "y")])
        #expect(state.openQuestions.first?.isOpen == false)
    }

    @Test func malformedResultRecordingLeavesStateUntouched() {
        var state = LiveMeetingState()
        state.apply(SemanticResult(meaning: "m", keyPoints: ["existing point"]), forTurns: [turn(1, "x")])
        let before = state
        state.recordMalformedResult()
        #expect(state.keyPoints == before.keyPoints)
        #expect(state.decisions == before.decisions)
        #expect(state.malformedResultCount == 1)
    }

    @Test func compactViewCapsKeyPointsToTheRequestedCount() {
        // Each fact shares only a 2-word prefix ("Point about") and differs
        // in its one distinguishing word — token-set Jaccard for any pair
        // stays at 0.5 (below the 0.6 dedup threshold), so all 20 stay
        // distinct entries and this only exercises the cap, not dedup.
        let words = ["apples", "bananas", "cherries", "dates", "elderberries", "figs", "grapes",
                     "honeydew", "indigo", "jasmine", "kiwis", "lemons", "mangoes", "nectarines",
                     "oranges", "papayas", "quinces", "raspberries", "strawberries", "tangerines"]
        var state = LiveMeetingState()
        for (i, word) in words.enumerated() {
            state.apply(SemanticResult(meaning: "m", keyPoints: ["Point about \(word)"]), forTurns: [turn(i, "turn \(i)")])
        }
        #expect(state.keyPoints.count == words.count)
        let view = state.compactView(maxKeyPoints: 5)
        #expect(view.keyPoints.count == 5)
        // Keeps the newest, not the oldest.
        #expect(view.keyPoints.last?.text.contains("tangerines") == true)
    }

    @Test func recentTurnsRingBufferStaysBounded() {
        var state = LiveMeetingState()
        for i in 0..<20 {
            state.apply(SemanticResult(meaning: "m"), forTurns: [turn(i, "turn \(i)")])
        }
        #expect(state.recentTurns.count == LiveMeetingState.caps.recentTurns)
        #expect(state.recentTurns.last?.id == 19)
    }
}
