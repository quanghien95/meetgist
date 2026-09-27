// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Testing
@testable import MeetGistKit

@Suite struct ExporterTests {
    @Test func srtFromTranscript() {
        let t = """
        [00:00] Me: hello
        [00:05] Speaker 1: hi there
        [01:02] Me: bye
        """
        let srt = Exporter.transcriptToSRT(t)
        #expect(srt.contains("00:00:00,000 --> 00:00:05,000"))
        #expect(srt.contains("Me: hello"))
        #expect(srt.contains("00:00:05,000 --> 00:01:02,000"))
        #expect(srt.contains("00:01:02,000 --> 00:01:05,000"))  // last +3s
        #expect(srt.hasPrefix("1\n"))
    }

    @Test func srtHandlesHourTimestamps() {
        let srt = Exporter.transcriptToSRT("[01:02:03] Me: late")
        #expect(srt.contains("01:02:03,000 -->"))
    }

    @Test func stripMarkdown() {
        let s = Exporter.stripMarkdown("# Title\n- **bold** and `code`")
        #expect(!s.contains("#"))
        #expect(!s.contains("**"))
        #expect(!s.contains("`"))
        #expect(s.contains("bold"))
    }

    @Test func formatExtensions() {
        #expect(Exporter.Format.srt.ext == "srt")
        #expect(Exporter.Format.json.ext == "json")
        #expect(Exporter.Format.allCases.count == 4)
    }
}
