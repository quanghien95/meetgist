# MeetGist Agent Guide

## Project scope

MeetGist is a local-first macOS meeting recorder. It captures microphone and
system audio, produces a canonical transcript, then generates meeting minutes
and summaries. The native macOS app is the active product path; the CLI and
scripts remain useful but may describe older workflows.

## Sources of truth

Use this order when information conflicts:

1. The current user request and accepted decisions.
2. The nearest `AGENTS.md`, if one exists.
3. Current implementation, `Package.swift`, and `app/project.yml`.
4. `docs/ARCHITECTURE.md` and focused engineering documents.
5. `docs/design.md` for visual/UI decisions.
6. `README.md` and `CONTRIBUTING.md` for general usage.

Do not turn an assumption, an old plan, or a benchmark result into a project
fact. State uncertainty explicitly.

## Component ownership

| Area | Primary code |
| --- | --- |
| App lifecycle and user flows | `app/Sources/AppState/` (`AppState.swift` + `AppState+Recording`, `+Processing`, `+Providers`, `+Library`, `+Runtimes`) |
| Settings and meeting UI | `app/Sources/SettingsView.swift`, `app/Sources/Library`, `app/Sources/MeetingDetailView.swift` |
| Recording and audio capture | `Sources/MeetGistKit/Recorder.swift`, `SessionRecorder.swift`, `AudioTools.swift` |
| Mic-track echo cancellation (pre-transcription preprocessing, P4b) | `Sources/MeetGistKit/EchoCancellation/` (`EchoPreprocess`, `MicEchoCanceller`, `EchoDelayEstimator`, `EchoAudioIO`, `TranscriptEchoDedup`, `AudioDeviceTransportHint`), `scripts/echo_report.py`. See `docs/mic-echo-fix-plan.md`. |
| Meeting files and list actions | `Sources/MeetGistKit/MeetingStore.swift` |
| Provider assembly and output contracts | `Pipeline.swift`, `Provider.swift`, `Prompts.swift`, `NotesTemplates.swift` |
| Cloud providers | `GeminiClient.swift`, `OpenAIClient.swift`, `CodexCLINotes.swift` |
| Offline MLX Whisper transcription | `OfflineJobCoordinator.swift`, `OfflineJobStore.swift`, `OfflineRuntimeManager.swift`, `Resources/offline_worker.py` |
| Offline Qwen3-ASR transcription | `Qwen3ASRRuntimeManager.swift`, `Resources/offline_worker_qwen.py` (same coordinator/store as Whisper) |
| Runtime setup shared by all local runtimes | `ManagedPython.swift`; offline engines share `ManagedOfflineRuntime` (`OfflineRuntimeManager.swift`) |
| Local Qwen notes | `LocalNotesRuntimeManager.swift`, `QwenMLXNotes.swift`, `Resources/qwen_notes_worker.py` |
| Apple on-device notes | `AppleFoundationModelsNotes.swift` |
| Subprocess supervision (cancel/timeout/kill, pipe draining) | `ChildProcess.swift` |
| Post-process script | `app/Sources/Automation/PostProcessRunner.swift` |
| Live Meeting Copilot ("Live Assist", V1 + V2) — fully isolated live path, disabled by default | `Sources/MeetGistKit/LiveCopilot/` (`LiveAssistSession` orchestrator, `LiveAudioFeed`/`SpeechEndpointer`, `QwenLiveTranscriber` + `Resources/live_asr_worker.py`, `LiveASRRuntimeManager`, `CopilotLLM`/`CopilotLLMAdapters`, `LiveCopilotEngine`, `LiveMeetingState`, `LiveCopilotPersistence`; V2 — Suggest Answer/Ask Meet Gist/manual context — adds `LiveAssistAnswer.swift` (answer type, parser, post-check, assist.jsonl entry) and `ManualFileContextProvider.swift`, implementing the `LiveContextProvider` seam), `app/Sources/AppState/AppState+LiveAssist.swift` (V1 wiring + V2: `liveAutoSuggest`, `suggestAnswer()`/`askMeetGist()`/`pickLiveContextFile()`), `app/Sources/LiveAssist/` (panel UI incl. V2 sections, settings, labels). See `docs/live-copilot-plan.md`. |
| Tests | `tests/MeetGistKitTests`, `tests/MeetGistAppTests` (both Swift Testing), `tests/test_*.py` (unittest); `tests/MeetGistKitTests/LiveCopilotBenchmarkTests.swift` is env-gated (`MEETGIST_LIVE_BENCH=1`) and excluded from `make test` |

## Architecture invariants

- Keep recording/audio capture, transcription, and notes generation separate.
  Do not change recording, sync, or audio behavior unless the task requires it.
- `transcript.md` is the canonical input to the notes stage. Preserve the
  existing `polished.md` and `summary.md` output contract and UI.
- Transcription and notes each have their own provider selection. The offline
  engines (Whisper, Qwen3-ASR) are transcription-only; Local Qwen is notes-only.
- The cloud pipeline writes `transcript.md` before calling the notes provider;
  a notes failure must never discard a finished transcript.
- A local provider must never silently fall back to a cloud provider.
- Preserve existing cloud-provider behavior. Prefer the smallest coherent
  extension over redesigning provider abstractions.
- Local runtimes are app-managed and isolated from meeting data:
  `OfflineWhisper/v1`, `Qwen3ASR/v1` and `LocalNotes/Qwen3-4B/v1` under
  Application Support. Every runtime pins CPython (SHA-256), installs from a
  hash-locked requirements file (`--require-hashes`) and downloads its model at
  an exact revision; keep new engines to the same standard.
- Recording has priority over any processing. Stop local workers and cancel any
  in-flight cloud/notes/post-process task before starting capture; completion
  handlers must check the process generation token before touching state.
- Spawn cancellable subprocesses through `ChildProcess`, never
  `waitUntilExit()` on undrained pipes.
- Live Assist must never affect recording, transcription or notes. It is
  disabled by default, requires a cloud provider (no on-device LLM), reads
  PCM only through the optional taps described in FLOW-6, and every failure
  in its path surfaces only through its own status — never `state`,
  `lastError`, `recorder`, `processTask`, or `processGeneration`.
- Mic-track echo cancellation (`EchoPreprocess.prepareMicTrack`) never
  modifies canonical `mic.m4a`/`system.m4a`; it only ever produces a derived,
  regenerable `<session>/transcription/mic.aec.wav`. A failure anywhere in
  that step falls back to raw `mic.m4a` with a status note — it must never
  fail transcription. `aec=<version>|off` is folded into
  `cloudTranscriptionConfigID`/`offlineConfigID` so a toggle of the setting
  never lets a checkpoint/part transcribed from the other mic audio be reused
  as if it were the same job; with the setting off, both config IDs are
  byte-identical to before this feature existed.

## Critical flows

- **FLOW-1 — Recording:** capture audio and timing/sync data into a meeting
  directory.
- **FLOW-2 — Cloud pipeline:** selected cloud transcription/notes providers run
  through the existing composed pipeline.
- **FLOW-3 — Offline transcription:** MLX Whisper or Qwen3-ASR writes resumable
  per-meeting state and transcript parts, then produces `transcript.md`.
- **FLOW-4 — Notes:** an existing transcript is sent only to the selected notes
  provider, which writes the established notes outputs.
- **FLOW-5 — Local Qwen setup/run:** the app installs the pinned runtime/model,
  runs a local MLX-LM worker, and stores its latest job metrics separately.
- **FLOW-6 — Live Assist (optional, isolated):** while recording, if enabled,
  optional PCM taps (`SystemAudioRecorder`'s live sink, a dedicated
  `LiveMicTap`) feed `LiveAssistSession`, which runs its own endpointing,
  a persistent local Qwen3-ASR worker, and a cloud `CopilotLLM` semantic pass
  to publish a `LiveAssistSnapshot` to the Live Assist panel and
  `<session>/live/`. It never touches `transcript.md`, `polished.md`,
  `summary.md`, or the recording/notes state machine.

## Working protocol

Before changing code, read the relevant architecture document and inspect the
owner code above. Check provider, persistence, cancellation, and UI impact.
Follow existing patterns and make the smallest change that fully solves the
request. Do not introduce a daemon, RAG/vector store, generic LLM framework,
or new persistence layer without an approved architecture decision.

After changing code, run `make test` (Swift Testing + Python unittest; works
with only the Command Line Tools) plus `swift build`, inspect the diff, and
report unverified items. `app/Sources` has a test target
(`tests/MeetGistAppTests`, `@testable import MeetGistApp`) covering
`AppState`'s processing lifecycle and settings via the injection points on
`AppState.init`; real recording (`SessionRecorder`/ScreenCaptureKit) and OS
permissions still need manual verification. For API, schema, or
persisted-data changes, check producers, consumers, backward compatibility,
retry/cancellation, and rollback behavior.

## Security and safety

- Do not print, commit, or document API keys, credentials, or private meeting
  content. Keep provider keys in the existing Keychain-backed path.
- Do not bypass download verification, sandboxing, or runtime isolation merely
  to make a local model run.
- Preserve unrelated working-tree changes. Avoid destructive Git commands.

## Known traps

- `docs/design.md` is a visual design document, not the architecture source.
- The README and CLI-oriented documents may lag the native app.
- `docs/offline-transcription-plan.md` is an implementation record, not a
  proposal for a new architecture.
- Qwen has one app-level `last-run-metrics.json`; Whisper persists progress and
  part timing per meeting instead of a single global last-run metric.
- With only the Command Line Tools, plain `swift test` cannot find the Swift
  Testing frameworks — use `make test`, which passes the needed flags. XCTest is
  not available there at all, so write new tests with Swift Testing. Never
  report tests as passing unless they actually ran.
- A clean build of the `MeetGistApp` target needs full Xcode: `KeyboardShortcuts`
  (all 2.x releases) uses `#Preview`, whose macro plugin ships only with Xcode.
- `AVAudioConverter`'s pull-based `convert(to:error:withInputHandler:)` is
  unreliable for a one-shot sample-rate conversion of a real file: it can
  assert `outputBuffer.frameCapacity >= inputBuffer.frameLength` as an
  uncaught Objective-C exception regardless of the actual up/downsampling
  ratio, fail outright with OSStatus -50, or simply never report
  `.endOfStream` once the input is exhausted (spinning forever with no new
  output) — none of this reproduces on small synthetic buffers, only on a
  real recording. `EchoAudioIO.decodeMono16k` (`Sources/MeetGistKit/EchoCancellation/`)
  works around all three by not using `AVAudioConverter` for the rate change
  at all: plain buffered `AVAudioFile.read(into:frameCount:)` at the file's
  native rate, then its own linear-interpolation resample.
- `docs/review-2026-09-26.md` is a point-in-time review; check its findings
  against the current code before acting on them.

## Definition of done

Deliver scoped code, focused tests or checks, error and cancellation handling,
preserved cloud behavior, and updated documentation when behavior changes.
Report assumptions, limitations, and any validation that could not run.
