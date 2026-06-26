# MeetGist · 记了吗

**English** | [中文](README.zh-CN.md)

**Get the gist. Skip the rest.** — *抓重点，去废话。*

**MeetGist is an open-source native Mac meeting recorder and AI notes app.**
Bot-free: it runs on your Mac and records your **microphone and the system audio
of any call separately** — Zoom, Google Meet, Tencent Meeting, Teams, Webex — then
turns each meeting into a timestamped verbatim transcript, polished minutes, and a
structured summary (TL;DR, decisions, action items). The two tracks are time-synced
(`capture_timing.json` → `sync_map.json`) for cleaner diarization. Works on
pre-recorded audio files too.

> This is the open-source engine (`meetgist`). A native Mac app + website live at
> **[meetgist.app](https://meetgist.app)**.

> **Status:** a personal, free, open-source project — provided **as-is** under
> AGPL-3.0, with **no warranty and no commercial support**. It is not a paid
> product or service. You bring your own free-tier AI API key.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-lightgrey)

> Nothing leaves your Mac until you transcribe, and only then — the audio is sent
> to your own Gemini (or optional OpenAI) API key. No accounts, no servers, no
> telemetry.

---

## Native app (developer preview)

A native SwiftUI app is included — a menu-bar recorder + a window with your
meetings, transcript / minutes / summary, and a Settings panel for your API key.
It reuses the same recording engine and prompts, with the whole pipeline in Swift
(no Python or ffmpeg).

Run it from Xcode:

```bash
open Package.swift          # opens the package in Xcode
# pick the “MeetGistApp” scheme (top bar), then press Run (⌘R)
```

or from the terminal: `swift run MeetGistApp`.

First run: macOS will ask for **Screen Recording** + **Microphone**. Open
**Settings** (gear) and paste a free-tier **Gemini API key**
(`aistudio.google.com/apikey`) to generate notes — without a key it still records
the audio. Code lives in `Sources/MeetGistApp/` (UI) and `Sources/MeetGistKit/`
(engine: recorder, prompts, Gemini pipeline). *Distribution as a signed/notarized
`.dmg` is not set up yet.*

---

## What you get

For every meeting (or audio file) meetgist writes a folder containing:

| File | Contents |
|---|---|
| `transcript.md` | Verbatim, timestamped lines — `[MM:SS] Speaker: text` |
| `polished.md` | Clean minutes: disfluencies removed, per-speaker stance, chapters, quotes, to-dos |
| `summary.md` | TL;DR, key decisions, action items, open questions |
| `mic.m4a` / `system.m4a` | The raw audio tracks |

It auto-detects the meeting language (Chinese ⇄ English, including code-switching)
and writes the notes in that language.

---

## How it works

```
Hotkey / ./meetgist-toggle.sh
        │
        ▼
meetgist (Swift binary)
   ├─ system audio  (ScreenCaptureKit → system.m4a)
   ├─ microphone    (AVFoundation    → mic.m4a)
   └─ on stop: hand both files to postprocess.py
        │
        ▼
scripts/postprocess.py  (Python venv)
   ├─ transcribe with Gemini (or OpenAI for very long audio)
   ├─ polish + summarize with Gemini
   └─ write transcript.md / polished.md / summary.md  +  macOS notification
```

The Swift recorder is a thin capture layer; all the AI work lives in the Python
scripts, so you can swap models or even go fully local later (e.g. whisper).

---

## Requirements

- **macOS 14+ on Apple Silicon**
- **Xcode Command Line Tools** — `xcode-select --install`
- **Python 3.10+**
- **ffmpeg** (only needed for long-audio chunking) — `brew install ffmpeg`
- **A Gemini API key** — free from [Google AI Studio](https://aistudio.google.com/apikey)

---

## Quick start

```bash
git clone https://github.com/MeetGist/meetgist.git
cd meetgist
./setup.sh
```

`./setup.sh` checks your prerequisites, builds the recorder, creates the Python
environment, and makes a `scripts/.env` for you. Then:

1. **Add your API key** — open `scripts/.env` and set:
   ```
   GEMINI_API_KEY=your-key-here
   ```
2. **Record** — run the toggle once to start, again to stop and transcribe:
   ```bash
   ./meetgist-toggle.sh
   ```
   The first time, macOS will ask for **Screen Recording** and **Microphone**
   permission (see [Permissions](#macos-permissions)).

That's it. Notes appear in `~/Documents/meetgist/<timestamp>/`.

> **Tip:** to start/stop with a keyboard shortcut, wire `./meetgist-toggle.sh` to a
> macOS Shortcut — see [Hands-free recording](#hands-free-recording-hotkey).

---

## Getting an API key

**Gemini (required, free tier available).** Go to
[aistudio.google.com/apikey](https://aistudio.google.com/apikey), create a key,
and paste it into `scripts/.env` as `GEMINI_API_KEY=...`. That single key powers
transcription, polishing, and summaries.

**OpenAI (optional).** For very long recordings you can route the transcription
step through OpenAI (Gemini still does polishing/summary). Add `OPENAI_API_KEY=...`
to `scripts/.env`; leave it blank to use Gemini for everything. See
[Configuration](#configuration).

---

## Transcribing a pre-recorded audio file

You don't have to record live — you can transcribe any audio you already have
(a voice memo, a downloaded recording, an interview, a Zoom export). The pipeline
is identical to live meetings; it just starts from your file.

**Supported formats:** `.m4a`, `.mp3`, `.wav`, `.mp4`

### One file

```bash
scripts/transcribe_meeting.sh ~/Downloads/interview.mp3
```

This writes the documents **in place** — right next to your audio file, named
after it: `interview.transcript.md`, `interview.polished.md`,
`interview.summary.md`. **Your original file is never modified**, and nothing is
copied into the meetgist output folder.

### Several files at once

```bash
scripts/transcribe_file.py a.mp3 b.m4a c.wav
```

### A whole folder of recordings

Point it at any folder; every audio file directly inside it is transcribed in
place, with its docs written right next to it:

```bash
scripts/transcribe_file.py ~/Downloads/voice-memos/
```

### Options (single file)

```bash
scripts/transcribe_file.py ~/Downloads/interview.mp3 --title "Candidate Interview" --source mic
```

| Flag | Default | Meaning |
|---|---|---|
| `--title`, `-t` | filename | Output filename prefix (single file only) |
| `--source` | `auto` | `mic` = single speaker labelled "Me"; `system`/`auto` = multi-speaker diarization (Speaker 1, 2, …) |

> A **meeting folder** that already contains `mic.m4a` and/or `system.m4a` can be
> passed straight to `scripts/transcribe_meeting.sh <folder>` to (re)transcribe it
> in place without copying.

### From Finder — right-click → Quick Action

Set this up once and you can transcribe any audio file (or meeting folder) just by
**right-clicking it in Finder** — no terminal needed:

1. Open **Shortcuts.app** → menu **File ▸ New Shortcut**.
2. In the details panel (ⓘ on the right), tick **Use as Quick Action** and
   **Finder**.
3. Set the shortcut to **Receive _Files and folders_** as input (top of the editor).
4. Add a **Run Shell Script** action and configure it:
   - **Shell:** `/bin/bash`
   - **Pass input:** **as arguments**
   - **Script** (replace `/path/to/meetgist` with where you cloned the repo):
     ```
     /path/to/meetgist/scripts/transcribe_meeting.sh "$@"
     ```
5. Name it e.g. **“Transcribe with meetgist”** and save.

Now right-click any `.m4a` / `.mp3` / `.wav` / `.mp4` file — a meeting folder, or
a folder you dropped one or more recordings into (e.g. a single `xxx.mp3` copied
in by hand) — in Finder → **Quick Actions ▸ Transcribe with meetgist**. A folder
without `mic.m4a`/`system.m4a` is treated as imported audio: each file is
transcribed **in place**, with `<name>.transcript.md` / `.polished.md` /
`.summary.md` written right next to it, and speakers are split from content (a
one-voice memo stays single-speaker; a conversation becomes Speaker 1 / Speaker 2
/ …). A macOS notification fires when the notes are ready. (The wrapper adds
Homebrew to `PATH` and logs to `logs/` so it works correctly in Finder's
restricted context.)

A recorded **meeting folder** (`mic.m4a`/`system.m4a`) is transcribed in that
same folder. Imported audio files get their docs next to the source. (The old
live-recording flow still lands sessions in your configured output directory,
default `~/Documents/meetgist`.)

---

## Recording meetings

### From the terminal

`./setup.sh` installs a set of terminal shortcuts into your shell config
(`~/.zshrc` or `~/.bashrc`). Open a new terminal (or `source ~/.zshrc`) and you
get:

| Command | What it does |
|---|---|
| `meetgist` | Start recording; run again to **stop + transcribe** |
| `gist-status` | Show whether it's recording or stopped |
| `gist-open` | Open the notes/output folder |
| `gist-last` | Open the most recent session folder |
| `gist-tx <file\|folder>` | Transcribe an existing audio file or meeting folder |

```bash
meetgist        # start… (a notification fires when you start and stop)
gist-status     # ● Recording  /  ■ Recording stopped
meetgist        # …run again to stop; notes are ready in ~30–120s
```

If you'd rather not use the aliases, every command maps to a script you can call
directly: `./meetgist-toggle.sh`, `./meetgist-toggle.sh status`,
`./meetgist-toggle.sh open`, `scripts/transcribe_meeting.sh <file>`.

### Hands-free recording (hotkey)

1. Open **Shortcuts.app** → new shortcut → add **Run Shell Script**.
2. Set the script to the absolute path of `meetgist-toggle.sh`, e.g.
   `/Users/you/meetgist/meetgist-toggle.sh`.
3. Assign a keyboard shortcut (e.g. `⌃⌥⌘R`) in the shortcut's settings.

Now one hotkey starts recording; pressing it again stops and transcribes. The
toggle script reads `MEETGIST_OUTPUT_DIR` from `scripts/.env`, so it behaves the
same whether launched by the hotkey or the terminal.

---

## Configuration

All settings live in `scripts/.env` (copied from `scripts/.env.example`).

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | — | **Required.** Your Google AI Studio key. |
| `MEETGIST_OUTPUT_DIR` | `~/Documents/meetgist` | Where recordings + notes are saved. Point it at a Dropbox/iCloud folder to sync across devices. |
| `GEMINI_MODEL` | `gemini-3.5-flash` | Audio-capable Gemini model for transcription/polishing. |
| `GEMINI_FALLBACK_MODEL` | `gemini-3.1-flash-lite` | Used if the primary Gemini call fails. |
| `TRANSCRIPT_PROVIDER` | `auto` | `auto` (Gemini, OpenAI for long audio), `gemini`, or `openai`. |
| `OPENAI_API_KEY` | — | Only needed when OpenAI transcription runs. |
| `OPENAI_TRANSCRIBE_MODEL` | `gpt-4o-mini-transcribe` | OpenAI transcription model. |

Advanced chunking/threshold knobs (`OPENAI_CHUNK_SECONDS`,
`GEMINI_CHUNK_SECONDS`, `GEMINI_AUDIO_REQUEST_MAX_MB`, …) are documented inline in
`scripts/.env.example`.

**Behavior summary:**
- Polishing + summary always use Gemini.
- `auto` routes a recording through OpenAI for transcription only when the largest
  track is large (≈16 MB+) and `OPENAI_API_KEY` is set; otherwise Gemini handles
  everything, chunking long audio automatically.
- `gemini` disables OpenAI; `openai` forces it.

List the models your key can use:

```bash
cd scripts && .venv/bin/python3 -c "
from google import genai; from dotenv import load_dotenv; import os
load_dotenv('.env')
for m in genai.Client(api_key=os.environ['GEMINI_API_KEY']).models.list(): print(m.name)"
```

---

## macOS permissions

Required once, granted to whichever app launches the recorder:

1. **Screen Recording** — for ScreenCaptureKit to capture system audio.
2. **Microphone** — for your voice.

- Launching from a terminal → grant both to your terminal app.
- Launching via a hotkey → grant both to **Shortcuts.app**.

Find them under **System Settings → Privacy & Security**. If a track comes out
near-empty (a few KB), it's almost always a missing permission — grant it, quit
and relaunch the launching app, and record again.

meetgist also **fails fast**: within a few seconds of starting it checks that
system audio is actually flowing, and if the Screen Recording permission is
missing it stops immediately with a notification instead of recording a silent
file for the whole meeting. A silent microphone only warns (it's normal for a
listen-only call), so system audio keeps recording.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mic.m4a` / `system.m4a` is ~1 KB | Permission issue — see [Permissions](#macos-permissions). |
| Recording stops in seconds: "no system audio" notification | Screen Recording permission is missing — grant it (see [Permissions](#macos-permissions)), relaunch the launching app, retry. |
| "Mic looks silent" notification | Microphone permission/mute — only a warning; system audio still recorded. Ignore it for listen-only calls. |
| `GEMINI_API_KEY not set` | Add it to `scripts/.env` (line must start with `GEMINI_API_KEY=`). |
| `404 ... models/... is not found` in `postprocess.log` | Your key can't see that model — set `GEMINI_MODEL` to one the list command above returns. |
| Recording starts but no "ready" notification | Check `~/Library/Caches/meetgist/meetgist.log` and the session's `postprocess.log`. |
| Hotkey does nothing | Shortcuts.app may need Accessibility permission; confirm "Use as Quick Action" is enabled. |
| Stale lock blocks start (after a crash) | `rm ~/Library/Caches/meetgist/meetgist.pid` |
| Re-transcribe existing audio without re-recording | `scripts/transcribe_meeting.sh "<session-folder>"` |

---

## Privacy & legal

- **Local-first.** Audio is only uploaded when `postprocess.py` runs, and only to
  *your own* API key. No third-party servers, accounts, or telemetry.
- **Recording consent.** Many places (e.g. California) require **two-party
  consent**. Announce that you're recording when others are present. You are
  responsible for complying with the laws that apply to you.
- The API key in `scripts/.env` is plaintext and is git-ignored — never commit it.

---

## Cost notes

- Gemini audio upload is ~30 MB per hour of meeting (both tracks). Files are sent
  to the Gemini Files API and deleted after the call (and auto-expire in 48h).
- Check current [Google AI Studio pricing](https://ai.google.dev/pricing) before
  large batches. The free tier is enough for casual use.

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Contributor License Agreement](CLA.md) — the CLA is accepted automatically on your
first pull request.

---

## License

Copyright © 2026 Longfu Xu.

meetgist is free software, licensed under the **GNU Affero General Public License
v3.0** (see [LICENSE](LICENSE)). You may use, study, share, and modify it; if you
run a modified version as a network service, you must offer users its source.

Contributions are accepted under a [CLA](CLA.md) that lets the project be
relicensed or dual-licensed in the future, which preserves the option of a
separate **commercial license**. For commercial licensing inquiries, contact the
maintainer via [GitHub](https://github.com/longfuxu).
