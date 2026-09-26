# MeetGist — Design System (v2)

> Brand: **MeetGist / 记了吗** · *Get the gist. Skip the rest. — 抓重点，去废话。*
> The good design here isn't "looks feature-rich" — it's "you barely feel it during
> the meeting, and it's instantly useful after."

## Visual direction (moodboard, in words)

Dark-first, graphite, **terminal/developer-tool** restraint. Flat surfaces, 1px
hairlines, no gradients, no blobs, no robot, no SaaS hero. Tiny terminal touches
(`▸` prompt, `●` status dots, monospaced numbers). Calm by default; the only
saturated color is a single **terminal-mint** accent (+ amber for warnings, red for
recording/errors). Think `htop` / a good CLI / Things-meets-Terminal.

## Palette (`app/Sources/Design/Theme.swift`)

| Token | Hex | Use |
|---|---|---|
| bg | `#0B0C0E` | window background |
| panel / panel2 | `#15171A` / `#1C1F24` | surfaces |
| line | `#262A30` | hairlines |
| text / muted | `#E6E8EB` / `#8A9099` | foreground |
| **mint** | `#5CF2B0` | primary accent (mic, primary buttons) |
| teal | `#38E0D0` | system audio, processing |
| amber | `#F2B85C` | warnings, paused |
| red | `#FF5C5C` | recording dot, errors |
| controlTint | `#1E9C6C` | native segmented pickers / checkboxes only (they draw white labels on the tint; bright mint is unreadable there). Don't tint popup pickers — they render dimmed. |

## Typography
- **SF Pro** for UI text.
- **SF Mono** for timers, audio levels, status codes, hotkey glyphs, the `▸` prompt —
  anything that should read as "instrument readout."

## Components (`app/Sources/Components/Components.swift`)
- **StatusPill** — `●` colored dot + mono label (pulses while recording).
- **LevelBar** — segmented mono blocks; mint for Mic, teal for System.
- **TimerLabel** — SF Mono, monospaced digits, `MM:SS` / `H:MM:SS`.
- **MintButton / GhostButton** — primary (mint on graphite) / secondary (hairline).
  Labels never wrap (`lineLimit(1)` + `fixedSize`); disabled buttons dim.
  `GhostButton(compact: true)` for icon-only toolbar buttons.
- **CardGroupBoxStyle** (`Design/Theme.swift`) — Settings sections: muted mono
  uppercase label above a full-width panel card with a 1px hairline; nested boxes
  step up to `panel2`.
- **MarkdownBlocksView** (`Components/MarkdownBlocks.swift`) — renders notes
  Markdown blocks (headings, `•` mint bullets, `☐/☑` tasks, numbered items, code
  fences); inline bold/italic/code via AttributedString. **TranscriptLineView** —
  mono muted `[MM:SS]`, speaker in mint (Me) / teal (others).
- **stepDot** (detail) — Transcribe → Summarize → Done stepper.

## States (idle / recording / paused / processing / done / failed)
Surfaced consistently in: the **menu-bar icon** (waveform / `record.circle.fill` /
pause / spinner / `!`), the **StatusPill** color, and the **HUD** glyph
(`●` REC / `■` Saved / `↻` / `✓` / `!`). Colors per `statusColor()`.

## Surfaces
- **Menu-bar popover** (`MenuBar/MenuBarPopover.swift`) — the primary, always-there
  surface: status + mono timer + live Mic/System meters + Start/Stop/Pause + open /
  transcribe-latest / settings. ~282pt, dark.
- **Hotkey + HUD** (`Hotkey/`) — global ⌥⌘K (KeyboardShortcuts); a borderless,
  non-activating panel flashes status for ~1.5s near the top-right, never covering
  the meeting. Menu-bar-only by default.
- **Mini controller** (`Recording/MiniController.swift`) — opt-in tiny floating
  NSPanel: timer + mic/system meters + stop + collapse; draggable.
- **Library** (`Library/LibraryView.swift`) — a pro Mac tool: searchable list,
  each row = title + `●` status dot (mint notes / teal transcript / muted saved,
  label in tooltip) + date + duration, value-first detail.
- **Detail** (`MeetingDetailView.swift`) — Summary → Minutes → Transcript, audio-track
  status (Mic `●` / System `●`), export (md/txt/srt/json), copy/reveal/regenerate,
  run post-process (icon). Header stays one row down to the 880pt minimum window:
  the title takes two lines max, the word/char stats drop out before anything wraps,
  and Re-transcribe sits on the tab row.
- **Settings** (`SettingsView.swift`) — General (Language, presence) · Hotkey · Audio
  (permission status) · Recording (folder, auto-transcribe, launch-at-login) · AI
  Provider (two-slot BYOK) · Privacy · About.

## Bilingual (`app/Sources/Localization/L10n.swift`)
Runtime layer (`Localization` + `L`): switching Language in Settings updates the UI
**instantly** (Follow System / English / 简体中文), no restart. Every label has an
EN + 中文 pair; UI metrics tolerate both lengths. `AppState` status/error text
goes through the same layer (`tr(L.x)`); values that vary (percentages, names)
use `L` functions returning an `LStr`, so each language keeps its own word
order. Product/model names, env vars and stored values stay untranslated;
progress text produced inside MeetGistKit is English.

## App icon
Master `icon.png` → `scripts/make-icon.sh` rasterizes the `AppIcon.appiconset`.
Concept: dual-track audio distilled into a few "gist" lines — no robot, no lone
mic, no people, no big text.

## Copy principles
"Bot-free", "low-distraction", "local-first", "you control recording" — never
"secretly record". Privacy framed as user-controlled + on-device-first.
