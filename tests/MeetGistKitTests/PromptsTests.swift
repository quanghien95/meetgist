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
        XCTAssertTrue(Prompts.polished.contains("---POLISHED---"))
        XCTAssertTrue(Prompts.polished.contains("---SUMMARY---"))
        XCTAssertTrue(Prompts.polished.contains("简体中文"))
    }
}
