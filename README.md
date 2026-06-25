# MeetGist · 记了吗

**Get the gist. Skip the rest.** — *抓重点，去废话。*

**MeetGist is an open-source native Mac meeting recorder and AI notes app.**
Bot-free: it runs on your Mac and records your **microphone and the system audio
of any call separately** — Zoom, Google Meet, Tencent Meeting, Teams, Webex — then
turns each meeting into a timestamped verbatim transcript, polished minutes, and a
structured summary (TL;DR, decisions, action items). The two tracks are time-synced
(`capture_timing.json` → `sync_map.json`) for cleaner diarization. Works on
pre-recorded audio files too.

> This is the open-source engine (`meetgist`). The polished native app + website
> live at **[meetgist.app](https://meetgist.app)**.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-lightgrey)

> Nothing leaves your Mac until you transcribe, and only then — the audio is sent
> to your own Gemini (or optional OpenAI) API key. No accounts, no servers, no
> telemetry. *(中文快速开始见文末。)*

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

---

## 中文快速开始

meetgist 是一个 **本地优先的 macOS 会议录音 + AI 转录工具**：同时录制你的麦克风和系统声音
（Zoom / 腾讯会议 / Google Meet 等），自动生成带时间戳的逐字稿、润色后的会议纪要、以及结构化
摘要（TL;DR、决策、待办）。音频只有在转录时才会上传，且只发送到你自己的 Gemini API key。

### 安装与配置

```bash
git clone https://github.com/MeetGist/meetgist.git
cd meetgist
./setup.sh                       # 自动检查依赖、编译、建环境、生成 .env
open scripts/.env                # 填入 GEMINI_API_KEY（在 https://aistudio.google.com/apikey 免费获取）
```

首次录音时，macOS 会请求「屏幕录制」和「麦克风」权限，到
**系统设置 → 隐私与安全性** 里给对应 App（终端 / Shortcuts.app）打勾即可。

### 录音方式一：终端快捷命令

`./setup.sh` 已自动把以下命令装进你的 shell 配置（`~/.zshrc`）。打开一个新终端
（或 `source ~/.zshrc`）即可使用：

| 命令 | 作用 |
|---|---|
| `meetgist` | 开始录音；再运行一次 **停止并自动转录** |
| `gist-status` | 显示当前是「录音中」还是「已停止」 |
| `gist-open` | 打开笔记/输出目录 |
| `gist-last` | 打开最近一次的会议文件夹 |
| `gist-tx <文件\|文件夹>` | 转录已有的音频文件或会议文件夹 |

```bash
meetgist        # 开始录音（开始/停止都会有系统通知）
gist-status     # ● 录音中  /  ■ 已停止录音
meetgist        # 再运行一次停止；约 30–120 秒后笔记就绪
```

### 录音方式二：用快捷键（Shortcut）一键录音

1. 打开 **Shortcuts.app（快捷指令）** → 新建一个快捷指令。
2. 添加 **Run Shell Script（运行 Shell 脚本）** 动作。
3. 脚本内容填 `meetgist-toggle.sh` 的绝对路径，例如
   `/Users/你的用户名/meetgist/meetgist-toggle.sh`。
4. 在快捷指令设置里给它指定一个键盘快捷键（如 `⌃⌥⌘R`）。

之后按一次快捷键开始录音，再按一次停止并自动转录——无需切到终端。

### 转录已有的音频文件（命令行）

适用于语音备忘录、下载的录音、采访等：

```bash
scripts/transcribe_meeting.sh ~/Downloads/录音.mp3      # 单个文件
scripts/transcribe_file.py a.mp3 b.m4a                  # 多个文件
scripts/transcribe_file.py ~/Downloads/录音文件夹/       # 整个文件夹
```

### 转录已有文件：在 Finder 里右键 → Quick Action

配置一次，以后在访达里**右键音频文件**就能转录，无需打开终端：

1. 打开 **Shortcuts.app** → 菜单 **文件 ▸ 新建快捷指令**。
2. 右侧详情面板（ⓘ）勾选 **用作快速操作（Use as Quick Action）** 和 **访达（Finder）**。
3. 把快捷指令的输入设为 **接收 _文件和文件夹_**。
4. 添加 **运行 Shell 脚本** 动作：**Shell** 选 `/bin/bash`，**传递输入** 选 **作为参数**，
   脚本填（把路径换成你 clone 的位置）：
   ```
   /path/to/meetgist/scripts/transcribe_meeting.sh "$@"
   ```
5. 命名为「**用 meetgist 转录**」并保存。

现在在访达里右键任意 `.m4a/.mp3/.wav/.mp4` 文件（或一个会议文件夹）→
**快速操作 ▸ 用 meetgist 转录**，转录完成后会有系统通知。

---

结果默认保存在 `~/Documents/meetgist/`；可在 `scripts/.env` 里用 `MEETGIST_OUTPUT_DIR`
改成 Dropbox / iCloud 等同步目录。许可证为 AGPL-3.0，贡献需接受 [CLA](CLA.md)。
