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
sh build.sh                # rebuild the recorder and app (release)
make setup                 # (re)create the Python venv from scripts/requirements.txt
```

## Before you open a PR

```bash
sh build.sh                                             # release build (CLI + app target)
make test                                                # Swift Testing suite + Python unit tests
bash -n meetgist-toggle.sh scripts/transcribe_meeting.sh  # shell scripts parse
python3 -m py_compile scripts/*.py                       # python compiles
```

`make test` works with either full Xcode or just the Command Line Tools (it adds
the extra Swift Testing framework flags the CLT toolchain needs). The app's
SwiftPM compile check works with macOS 27 Command Line Tools: the pinned local
`Vendor/KeyboardShortcuts` copy omits preview-only macros, and SwiftUI state
uses the SDK's compatible property wrapper through `CompatibleState`. Building
the signed `.app` with `make app` still requires full Xcode. Swift tests live
in `tests/MeetGistKitTests/` and use Swift Testing (`import Testing`), not XCTest.
There is no CI: run these checks locally before pushing. `MEETGIST_NETWORK_TESTS=1 make test`
also runs the opt-in tests that hit the network (real pinned CPython download).

`sh build.sh` and `make build` retain release optimization and the existing
`.build/release/meetgist` / `.build/release/MeetGistApp` outputs. The script
anchors the package path to its own directory and never cleans the cache.
On Swift 6.4 with standalone Command Line Tools, it temporarily selects the
`native` backend: the new default `swiftbuild` backend adds invalid Xcode-style
CLT search paths ([SwiftPM #10557](https://github.com/swiftlang/swift-package-manager/issues/10557)),
and locally recompiles/relinks unchanged release targets. Other toolchains
keep SwiftPM's default. Native's deprecation warning remains visible; revisit
this workaround when upgrading the toolchain. To opt into the new backend:

```bash
MEETGIST_BUILD_SYSTEM=swiftbuild sh build.sh
```

The first build with a different backend has a separate cache to populate.
Afterwards, unchanged builds should be quick. Release builds after code changes
still take longer than debug builds because Swift optimizes whole modules.
`swift build` remains the standard debug compile check; on CLT 27 its default
backend can still emit the upstream search-path warnings.

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
