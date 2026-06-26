// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Prompt strings ported verbatim from `scripts/postprocess.py` so the native app
/// produces identical transcripts/minutes/summaries. Two calls: audio → transcript,
/// then transcript text → polished + summary. Keep these in sync with the Python.
public enum Prompts {

    /// Format seconds as `MM:SS` or `HH:MM:SS` (mirrors postprocess.format_timestamp).
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Call 1: audio → transcript. `micExists`/`systemExists` pick two-track
    /// ("Me" / "Participant N") vs single-track ("Speaker N") diarization.
    public static func transcript(micExists: Bool,
                                  systemExists: Bool,
                                  segmentOffsetSeconds: Double? = nil) -> String {
        let trackDesc: String
        let speakerRule: String
        if micExists && systemExists {
            trackDesc = """
            Two synchronized audio tracks are attached:
            - First file (mic.m4a): MY microphone — attribute speech here to "Me".
            - Second file (system.m4a): system audio — other participants speaking.
            Both start at the same moment and have the same duration.
            """
            speakerRule = #"Speech on mic.m4a = "Me". On system.m4a, distinguish voices as "Participant 1", "Participant 2", etc.; use names when participants self-introduce or are addressed by name."#
        } else {
            trackDesc = """
            One audio track is attached containing a meeting recording.
            Distinguish speakers as "Speaker 1", "Speaker 2", etc.
            When participants self-introduce or are addressed by name, use those names instead of "Speaker N".
            """
            speakerRule = #"Distinguish voices as "Speaker 1", "Speaker 2", etc. When participants self-introduce or are addressed by name, use those names instead."#
        }

        var segmentNote = ""
        if let offset = segmentOffsetSeconds {
            segmentNote = """

            This audio is one segment of a longer recording. The segment starts at
            \(timestamp(offset)) in the full recording. Use timestamps
            relative to this segment, starting at [00:00]; the app will convert them back
            to full-recording timestamps.
            """
        }

        return """
        \(trackDesc)
        \(segmentNote)

        Transcribe this meeting VERBATIM. Output ONLY the transcript in this format:

        ---TRANSCRIPT---
        [MM:SS] Speaker: verbatim speech
        [MM:SS] Speaker: verbatim speech
        ...

        Rules:
        - Preserve the speaker's original language verbatim. Do not translate. If a
          speaker mixes English and Chinese in one utterance, keep both.
        - \(speakerRule)
        - Use [MM:SS] timestamps (or [HH:MM:SS] for meetings longer than one hour).
        - Only include lines with actual spoken content. Skip long silences.
        - Be THOROUGH — transcribe every utterance. Do not summarize or skip material.
        - Output ONLY the ---TRANSCRIPT--- section. No summary, no commentary.

        """
    }

    /// Call 2 (template mode): fill the user's own template from the transcript.
    public static func templatedNotes(_ template: String) -> String {
        """
        Below is a verbatim meeting transcript. Produce meeting notes by filling in the
        TEMPLATE below using only what's in the transcript.

        Rules:
        - Keep the template's exact structure, sections, and headings.
        - Fill each section from the transcript. If a section has no relevant content,
          write "—". Do not invent information.
        - Write in the dominant language of the transcript (Simplified Chinese if the
          transcript is mostly Chinese, otherwise English).
        - Output ONLY the filled template — no preamble, no commentary.

        TEMPLATE:
        \(template)
        """
    }

    /// Call 2: transcript text → polished minutes + summary (text-only, no audio).
    public static let polished: String = """
    Below is a verbatim meeting transcript. Based on it, produce two sections.

    First, decide a LANGUAGE:
    - If the dominant spoken language in the transcript is Chinese (Mandarin or
      Cantonese, in any script), LANGUAGE = Simplified Chinese (简体中文).
    - Otherwise (English, mixed, or any other language), LANGUAGE = English.

    Output in EXACTLY this format:

    ---POLISHED---
    # [Meeting Title or "Meeting Minutes"]

    ## Smart Summary
    (2-3 sentence overview in LANGUAGE)

    ## Recording Information
    - **Duration**: ...
    - **Number of participants**: ...
    - **Content type**: ...

    ## [Topic sections — create headings based on meeting flow]
    ### [Section Title]
    - **Speaker Name**: cleaned-up version of what they said (no ums, ahs, filler words, repetitions, or broken sentences; meaning preserved, no new info added)
    ...

    ## Chapter Summary
    [MM:SS] **Chapter Title** — brief description of what happened in this segment
    ...

    ## Selected Quotes
    - "..." (Speaker Name) — (Strategic insight / Thinking inspiration / Key decision)
    ...

    ## To-do Items
    - [ ] Owner - task description

    ## Per-Speaker Stance
    - **Speaker Name**:
      - Claimed / Argued: what positions, arguments, or opinions they expressed
      - Committed to: what actions or follow-ups they agreed to take on
    ...

    ---SUMMARY---
    ## TL;DR
    (2-4 sentences in LANGUAGE)

    ## Key Decisions
    - ... (in LANGUAGE)

    ## Action Items
    - [ ] Owner - task (due: date if mentioned)   <- in LANGUAGE

    ## Open Questions / Follow-ups
    - ... (in LANGUAGE)

    ## Notable Context
    (anything important for future reference, in LANGUAGE)

    Rules:
    - POLISHED: same content as the transcript but disfluencies removed, repeats
      merged, broken sentences healed — make it clear, detailed, and ready for
      reading. Meaning preserved, no new information added.
      Write entirely in LANGUAGE.
      If LANGUAGE is Simplified Chinese: use natural Chinese section headings
      (e.g. "📑 智能摘要", "📋 待办事项", "✨ 精选语录", "📅 章节摘要", "👥 各发言人立场").
      If LANGUAGE is English: use English section headings.
    - SUMMARY (everything after ---SUMMARY---): write entirely in LANGUAGE.
      If LANGUAGE is Simplified Chinese: section headings stay as
      "## TL;DR / ## Key Decisions / ## Action Items / ## Open Questions /
      Follow-ups / ## Notable Context" (do not translate the headings), but ALL
      content under them is in 简体中文. Use 简体, never 繁體.
      If LANGUAGE is English: everything in English.
    - Be polished and readable on the POLISHED section; be punchy on the summary.
    """
}
