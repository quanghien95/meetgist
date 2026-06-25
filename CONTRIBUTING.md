# Contributing to MeetGist

Thanks for your interest in MeetGist — a local-first meeting recorder and
transcriber for macOS. This guide covers the license/CLA requirement and the dev
setup.

## License & CLA (read first)

- MeetGist is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)).
- Every contributor must accept the **[Contributor License Agreement](CLA.md)** on
  their first pull request (handled automatically by the CLA Assistant bot). The
  CLA keeps the project relicensable/dual-licensable in the future — it is **not**
  optional. A PR cannot be merged until the CLA check passes.
- **Do not submit code under a NonCommercial or field-restricted license** (e.g.,
  CC-BY-NC). Permissive third-party code (MIT/BSD/Apache) is fine if you attribute
  it and note its license in the PR.

## Project layout

```
Sources/meetgist/      Swift recorder (ScreenCaptureKit + AVFoundation)
scripts/              Python transcription pipeline (Gemini / OpenAI)
meetgist-toggle.sh     Start/stop toggle invoked by the macOS Shortcut
setup.sh              One-command build + venv + .env bootstrap
Makefile              build / setup / install / clean targets
```

See the [README](README.md#architecture) for how the pieces fit together.

## Dev setup

Prerequisites: macOS 14+ on Apple Silicon, Xcode Command Line Tools
(`xcode-select --install`), Python 3.10+, and [`ffmpeg`](https://ffmpeg.org)
(`brew install ffmpeg`).

```bash
./setup.sh                 # builds the Swift binary, creates the venv, copies .env
# then edit scripts/.env and add your GEMINI_API_KEY
```

Or step by step:

```bash
swift build -c release     # rebuild the recorder after editing Sources/
make setup                 # (re)create the Python venv from scripts/requirements.txt
```

## Before you open a PR

```bash
swift build -c release                                   # must compile cleanly
bash -n meetgist-toggle.sh scripts/transcribe_meeting.sh  # shell scripts parse
python3 -m py_compile scripts/*.py                       # python compiles
```

A good manual smoke test: record a short session (hotkey or `meetgist`), confirm
`transcript.md` / `polished.md` / `summary.md` land in your output folder, and try
`scripts/transcribe_meeting.sh <some-audio-file>` for the pre-recorded path.

- Match the surrounding code style; keep changes focused and minimal.
- New source files should carry an SPDX header: `SPDX-License-Identifier: AGPL-3.0-only`.
- User-configurable environment variables use the `MEETGIST_` prefix.
- Don't hardcode machine-specific paths — derive them from the script/binary
  location or read them from `scripts/.env` (see how `MEETGIST_OUTPUT_DIR` is used).

## Reporting issues

Open a GitHub issue with steps to reproduce, expected vs. actual behavior, your
macOS version, and the relevant log (`~/Library/Caches/meetgist/meetgist.log` or the
session's `postprocess.log`). For security-sensitive reports, contact the
maintainer privately through GitHub rather than filing a public issue.
