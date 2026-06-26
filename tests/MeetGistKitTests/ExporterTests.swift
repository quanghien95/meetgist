// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import XCTest
@testable import MeetGistKit

final class ExporterTests: XCTestCase {
    func testSRTFromTranscript() {
        let t = """
        [00:00] Me: hello
        [00:05] Speaker 1: hi there
        [01:02] Me: bye
        """
        let srt = Exporter.transcriptToSRT(t)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:05,000"))
        XCTAssertTrue(srt.contains("Me: hello"))
        XCTAssertTrue(srt.contains("00:00:05,000 --> 00:01:02,000"))
        XCTAssertTrue(srt.contains("00:01:02,000 --> 00:01:05,000"))  // last +3s
        XCTAssertTrue(srt.hasPrefix("1\n"))
    }

    func testSRTHandlesHourTimestamps() {
        let srt = Exporter.transcriptToSRT("[01:02:03] Me: late")
        XCTAssertTrue(srt.contains("01:02:03,000 -->"))
    }

    func testStripMarkdown() {
        let s = Exporter.stripMarkdown("# Title\n- **bold** and `code`")
        XCTAssertFalse(s.contains("#"))
        XCTAssertFalse(s.contains("**"))
        XCTAssertFalse(s.contains("`"))
        XCTAssertTrue(s.contains("bold"))
    }

    func testFormatExtensions() {
        XCTAssertEqual(Exporter.Format.srt.ext, "srt")
        XCTAssertEqual(Exporter.Format.json.ext, "json")
        XCTAssertEqual(Exporter.Format.allCases.count, 4)
    }
}
