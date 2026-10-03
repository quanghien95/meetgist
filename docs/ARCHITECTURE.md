# MeetGist Architecture

## Purpose and scope

MeetGist is a native macOS, local-first meeting application. It records audio,
creates a transcript, and generates meeting minutes and summaries. This
document describes the current native-app architecture; visual decisions belong
in [design.md](design.md).

For documentation priority and engineering rules, see [AGENTS.md](../AGENTS.md).

## System map

```text
SwiftUI views
    │
    └── AppState ── MeetingStore ── meeting directory
             │
             ├── Recorder / SessionRecorder ── audio capture + sync data
             ├── transcription provider slot
             │     ├── cloud provider
             │     ├── Offline MLX Whisper worker
             │     └── Offline Qwen3-ASR worker (MLX Audio)
             └── notes provider slot
                   ├── cloud provider
                   ├── Apple Foundation Models
                   └── Local Qwen MLX-LM worker
```

`MeetGistKit` owns the product behavior and persistence. `app/Sources` owns
SwiftUI presentation and user interaction. Cloud providers are external,
user-configured services; no server component owns meeting data.

## Data and output contracts

Meeting data lives in its meeting directory. Audio, capture timing/sync data,
and processing artifacts belong to that directory. A successfully transcribed
meeting has `transcript.md`, which is the sole canonical input to notes
generation. Notes providers keep the existing output contract:

- `polished.md` — cleaned transcript/notes presentation.
- `summary.md` — meeting minutes or summary shown by the existing UI.

The offline engines additionally store resumable state, committed part results,
and the worker's stdout/stderr (`worker.log`) under the meeting's
`transcription/` directory. These are job-recovery and diagnostic data, not a
replacement for the canonical transcript.

## Provider boundaries

There are two independent provider selections:

| Capability | Providers | Boundary |
| --- | --- | --- |
| Transcription | Existing cloud providers, Offline MLX Whisper, Offline Qwen3-ASR | Produces `transcript.md` |
| Notes / summary | Existing cloud providers, Apple Foundation Models, Local Qwen MLX-LM, Codex CLI | Consumes `transcript.md`; produces existing notes outputs |

The composed cloud pipeline remains intact for existing cloud behavior. Local
workers are explicit selections and must never silently fall back to cloud.
The offline transcription engines do not generate notes; Local Qwen does not
transcribe audio. Provider capabilities (needs an API key, runs on device, …)
are typed (`TranscribeStyle` / `NotesStyle` in `Provider.swift`) rather than
re-derived from strings at each call site.
Codex CLI is a cloud provider, not a local one, even though it runs as a local
subprocess: it sends the transcript to OpenAI over the user's own ChatGPT
subscription session (`codex login`). It requires no API key and no
MeetGist-managed runtime/model install — the prerequisite is that the user
already has `codex` installed and logged in. Real-world testing found `codex
exec` can occasionally hang indefinitely for reasons outside MeetGist's
control; `CodexCLINotes.swift` enforces a 120s timeout so this cannot block
Generate/Regenerate forever.

With automatic transcription enabled, cloud and Offline MLX Whisper follow the
same user-visible completion sequence: transcript, then the selected notes
provider writes `polished.md` and `summary.md`. If post-processing is enabled,
its local Python source runs only after both notes outputs exist; captured
stdout/stderr (capped at 1 MB per stream) is stored as `postprocess-output.md`
in the meeting directory. The script is stopped after 10 minutes, and is
cancelled with the rest of the job by Cancel or by starting a recording.

## Meeting detection

The app observes only the frontmost application and visible window title to
offer a best-effort floating “Record now” prompt for Google Meet and Microsoft
Teams. It does not read browser history, meeting content, or send detection
data off device. The setting can disable this behavior.

## Critical flows

### Recording

`Recorder` and `SessionRecorder` capture microphone/system audio and timing
data. `MeetingStore` owns meeting-list mutations and meeting-directory actions.
This path is independent of model selection.

A session folder is named `yyyy-MM-dd-HHmm[-title]` (POSIX locale, which
`MeetingStore` parses back as the meeting date). If that folder already exists
— two recordings in the same minute — a `-2`, `-3`, … suffix is appended so an
earlier recording's audio is never reused or overwritten. If the microphone
fails to start after system capture started, system capture is stopped again.

### Importing audio and video

The Library's **Import Audio or Video…** picker accepts audio and movie files
supported by macOS AVFoundation, including MP4 and MOV. `AudioTools.export`
extracts/transcodes only audio using the AppleM4A preset into a new meeting's
`mic.m4a`; it never copies the original video into meeting storage. The source
file remains unchanged. A video without an audio track is rejected. Failed or
cancelled imports remove their newly created session folder and partial audio.
Imports use the same cancellable task/generation guard as processing, so starting
a recording cancels and awaits extraction before capture starts. Successful
imports use the usual automatic transcription/notes settings.

### Cloud processing

The existing `Pipeline`/`Provider` composition invokes the selected cloud
providers and preserves their previous transcript-to-notes behavior.
`MeetingProcessor.process` runs it as two stages and writes `transcript.md`
as soon as transcription succeeds, before the notes provider is called — a
notes failure (quota, network, bad model name) leaves the transcript on disk
and the meeting can be retried from Generate, the same contract the offline
path already had.

Every cloud HTTP call goes through `HTTPRetry` (MeetGistKit): HTTP 408/429/5xx
and transient network errors are retried up to 3 times with exponential backoff
and jitter (honoring `Retry-After`, capped at 30 s), reported through the
normal progress text. Other 4xx errors fail immediately. Long model calls
(generate, chat, transcribe) never retry a client-side timeout, since the
provider may still be processing — and billing — that request. Backoff sleeps
stop promptly on cancellation.

`GeminiTranscriber` and `WhisperTranscriber` split long audio into
`kMeetGistChunkSeconds` chunks and, once `HTTPRetry`'s retries are exhausted on
one chunk, used to lose every already-transcribed chunk on the next attempt.
`CloudTranscriptionCheckpoint` now persists each successfully transcribed
chunk's final (already offset-adjusted) text atomically under
`<sessionDir>/cloud-transcription/<configID>/<track>-<index>.txt` —
`<track>` is the aligned window index for Gemini (one call already spans every
track) and the speaker-track name for Whisper (each track is transcribed
independently) — and `CloudChunkTranscription.run` reuses any chunk already on
disk for the same `configID` before calling the API again, reporting "Reusing
N of M transcribed chunks…". `configID` (`cloudTranscriptionConfigID`) folds in
provider style, model, base URL, chunk length, and which tracks exist, so
switching provider/model/base URL never reuses another config's chunks — the
same role `offlineConfigID` plays for the offline engines. Writes use the same
atomic write-`.tmp`-then-`rename` pattern as `OfflineJobStore`, so a cancelled
or crashed chunk is never mistaken for a committed one.
`MeetingProcessor.process` deletes the whole checkpoint tree right after
`transcript.md` is durably written: it's regenerable cache, not part of the
transcript contract, so a plain Regenerate of an already-finished meeting
simply recomputes every chunk rather than risk reusing chunks from
stale/replaced audio.

### Offline transcription (MLX Whisper, Qwen3-ASR)

Each offline engine has its own runtime manager (`OfflineRuntimeManager`,
`Qwen3ASRRuntimeManager`) and its own `OfflineJobCoordinator`, which schedules
a single resumable job running the bundled worker (`offline_worker.py` /
`offline_worker_qwen.py`). `OfflineJobStore` persists progress and committed
parts; part IDs are namespaced by engine+model so switching engines never
reuses incompatible output. Completion writes the regular transcript contract,
after which the normal notes stage can run. Cloud and offline transcription
read the canonical `mic.m4a` and `system.m4a` directly. Mic-track echo
preprocessing and the cloud Whisper transcript echo deduplication were removed
on 2026-10-03 because their behavior was unsatisfactory in use. Existing
derived audio is ignored; checkpoints/parts with an AEC config suffix are
not reused by new jobs. Completed transcripts remain unchanged until an
explicit re-transcription. Live Assist retains its separate live turn filter.

Qwen3-ASR uses 30-second, non-overlapping chunks. Its MLX decoder has a
512-token output cap per chunk; repeated or implausibly long output is retried
on successively shorter audio down to 7.5 seconds. If even that fails, the job
fails instead of committing a hallucinated part. Qwen's part config ID is `v2`
so old 300-second parts are not reused; existing completed transcripts are
left in place until the user explicitly re-transcribes them. Whisper's chunk
size and config ID are unchanged.

Progress and completion are event-driven: the coordinator reloads job state
when the worker atomically replaces `transcription/state.json` (a file-system
watch on that directory) and learns about exit from the process's termination
handler; `AppState` follows the published job state and awaits
`waitUntilFinished(sessionID:)` instead of polling.

Listing jobs (`scan`) is read-only (`OfflineJobStore.recoveredView()`) and
skips any session that is active on either coordinator; the repairing
`recover()` (delete stale `*.tmp`, reset `transcribing` → `pending`) runs only
when a job is actually prepared to start or resume.

### Notes generation

The selected notes provider reads the existing transcript. `NotesWriter` and
the existing templates/prompts own output formatting. Apple on-device notes and
Local Qwen use chunk/reduce handling where needed for long transcripts without
changing the transcript contract.

### Local Qwen MLX-LM

`LocalNotesRuntimeManager` installs and validates the pinned Qwen runtime and
model (`mlx-community/Qwen3-4B-Instruct-2507-4bit`, with the revision pinned in
code via `LocalNotesModelConfig`). `QwenMLXNotes` runs `qwen_notes_worker.py`
as an app-managed local process. After setup, generation is offline. The
worker performs one model load per Generate/Regenerate job. Most meetings fit
the direct-context token budget and get a single final generation call; only
transcripts above that budget fall back to chunked map/reduce condensation
before the final call. Token budgets and sampler settings live in
`LocalNotesModelConfig` (Swift) and are passed to the worker as CLI flags, so
swapping the pinned model only requires changing that one config.

## Runtime storage and lifecycle

App-managed runtimes are kept outside meeting data in Application Support:

```text
MeetGist/
├── OfflineWhisper/v1/
├── Qwen3ASR/v1/
└── LocalNotes/Qwen3-4B/v1/
    └── last-run-metrics.json
```

Every runtime pins its CPython build (SHA-256 verified), installs Python
packages from a bundled hash-locked requirements file with `pip install
--require-hashes`, and downloads its model at an exact Hugging Face commit
revision. Each writes a `ready.json` marker recording those versions. The shared steps live in
`ManagedPython`; the two offline engines are one `ManagedOfflineRuntime`
implementation configured by an `OfflineRuntimeConfig` (root path, lockfile,
model repo + revision, readiness file), so a new engine declares these values
instead of copying the installer.

Qwen's metric file describes only the most recent local Qwen notes job. It
includes total elapsed time, wall-clock time, model load, reliable MLX
prefill/decode timing, token counts/rate, peak memory, source chunk count, and
a breakdown of map/reduce/final LLM call counts (so a direct-context run and a
map/reduce fallback run are distinguishable) when available. Whisper uses
per-meeting job state and part timing instead.

Recording has priority over any processing. Before capture begins the app
stops an active offline worker and cancels (and awaits) any in-flight cloud,
notes or post-process task. Each processing task carries a generation token,
so a task that finishes after being superseded can no longer overwrite the
recording's state. Local work must support normal cancellation and failure
reporting.

### Subprocesses

Every cancellable child process (Codex CLI, the Local Qwen worker, the
post-process script) goes through `ChildProcess` in MeetGistKit: stdout/stderr
are drained concurrently (no pipe-buffer deadlock), output is capped, and Swift
task cancellation or an optional timeout sends SIGTERM to the child's process
group, then SIGKILL after a 2 s grace period. The offline transcription worker
is supervised by `OfflineJobCoordinator` with the same terminate-then-kill
policy.

## Live Copilot ("Live Assist", V1)

An optional, fully isolated live path (`docs/live-copilot-plan.md`), disabled
by default (`AppState.liveAssistEnabled`). It never feeds the canonical
`transcript.md`/notes pipeline and never affects recording:

```text
SystemAudioRecorder's live PCM sink ─┐
                                     ├─ LiveAudioFeed (per track: mono, 16kHz)
LiveMicTap (AVAudioEngine, no VP) ───┘        │
                                       SpeechEndpointer (energy VAD)
                                               │  finalized SpeechSegment
                                       RealtimeTranscriber
                                       (QwenLiveTranscriber ↔ live_asr_worker.py,
                                        persistent per-recording process)
                                               │  LiveTranscriptTurn
                                       LiveCopilotEngine (actor)
                                         ├─ LiveTurnFilter (junk/dup/echo)
                                         ├─ scheduler (≤1 in-flight, coalesced,
                                         │   seq/generation-guarded, circuit breaker)
                                         ├─ CopilotLLM (Gemini | OpenAI-compatible | Codex CLI)
                                         └─ LiveMeetingState (dedup + evidence guards)
                                               │  LiveAssistSnapshot
                                       AppState+LiveAssist (@MainActor) → LiveAssistPanel
```

`LiveAssistSession` (Kit) is the single orchestrator wiring the above for one
recording; `AppState+LiveAssist.swift` only starts/stops/pauses/resumes it
and observes its snapshots — every dependency (transcriber, LLM, audio
sources) is injected there via test seams
(`liveTranscriberFactory`/`copilotLLMFactory`/`liveAudioSourceFactory`), so
Live Assist is unit-testable without audio, Python, or network.

The floating Live Assist panel opens at 640 × 720 points (bounded by the
screen's available space) and can be resized using its native window edges
or corners, down to 440 × 360 points. Its content wraps to the current width
and scrolls vertically, while the header and Ask Meet Gist input stay visible.
Transcript text is selectable and no longer truncated to two lines. Snapshot
updates preserve the window size; hiding and showing the same panel retains
its current size and position for the app session.

The panel opens on a Transcript tab showing a chronological history of
finalized, live-filter-accepted ASR turns, with a start–end timestamp relative
to the recording anchor and a speaker/mic label for every utterance. Earlier
text stays available as new turns arrive; it is selectable and scrollable,
and new turns do not force the reader to jump to the bottom. The separate
Live Assist tab retains the meaning, questions, notes and suggested answers.
This reading history is kept in memory for the live session and survives
status changes, provider changes and stopping that session. A new live
session starts empty. It is independent of the short semantic context and
the bounded Ask Meet Gist history; it never expands LLM prompts or writes
to the canonical `transcript.md`.

**Isolation.** `startLiveAssistIfEnabled` runs in its own `Task` after
`rec.start()` has already succeeded; any error in that path only ever sets
`liveAssist`'s own published state, never `state`/`lastError`/`recorder`/
`processTask`/`processGeneration`. `stopLiveAssist()` runs at the very start
of `stopRecording()` (and before offline/cloud processing begins, to free the
live-ASR worker's memory) with a hard 2s cap, so a slow worker/subprocess
teardown never delays saving the recording's audio. A local/on-device Notes
provider is never silently reused for Live Assist — it requires an explicit
cloud `CopilotLLM` (Gemini, an OpenAI-compatible chat provider, or Codex CLI);
on-device providers are rejected with a clear message.

**Privacy boundary.** Audio never leaves the machine for Live Assist: PCM
goes only to the local `live_asr_worker.py` process via a private temp file
deleted after use. Only transcribed text — the current turn(s), 2–3 recent
turns, and a compact rolling meeting state — is sent to the selected cloud
provider for the per-turn semantic pass; never raw audio, never the whole
meeting's history. Codex CLI runs with `--sandbox read-only --ephemeral` in
an empty temp directory, never the user's project files. Persistence under
`<session>/live/` (`turns.jsonl`, `state.json`, `metrics.jsonl` +
`metrics-summary.json`, `asr-worker.log`) is non-canonical: nothing reads it
back for transcription or notes, and it is deleted along with the rest of the
meeting folder like any other file in it (`MeetingStore.list`/`Exporter`
never look inside it; delete is a plain `NSWorkspace.recycle` of the whole
session directory).

Realtime ASR (`LiveASRRuntimeManager`) is a separate app-managed runtime root
from the one-shot offline Qwen3-ASR engine — same pinned `mlx-audio` stack,
but a persistent process (loaded once per recording) instead of once per
job, pinned to the 4-bit `Qwen3-ASR-0.6B` build by default for latency (the
post-meeting offline/cloud pipeline is the accuracy backstop for the
canonical transcript — see `docs/live-copilot-plan.md` §13 for the 4-bit vs
8-bit measurements this decision is based on).

### V2 — Live Assistant (Suggest Answer, Ask Meet Gist, manual context)

Built on the exact same `LiveCopilotEngine`/`CopilotLLM`/persistence
infrastructure as V1, with its own scheduling slot so it can never delay the
V1 per-turn semantic loop:

```text
"Suggest Answer" press (questionID)  ──┐
Ask Meet Gist text field (question)  ──┤
                                        ▼
                          LiveCopilotEngine.suggestAnswer/ask
                            ├─ separate in-flight slot/seq/generation from V1
                            │   (≤1 V2 request in flight; a new one cancels
                            │    the old; V1's scheduler is untouched)
                            ├─ bounded context:
                            │    Suggest Answer: ≤8 recent turns + compact state
                            │    Ask: last `askWindowMinutes` (10) of turns
                            │         (≤8k chars) + compact state
                            │    + optional ManualFileContextProvider snippet
                            ├─ CopilotLLM (same provider selection as V1;
                            │   Codex CLI answer/ask timeout 60s, HTTP 20s,
                            │   reasoning effort "none" — same latency-first
                            │   policy as V1's semantic calls)
                            ├─ LiveAssistAnswerParser (tolerant JSON decode)
                            ├─ LiveAssistAnswerPostCheck (an unsupported
                            │   "known_from_meeting" claim — no token overlap
                            │   with TURNS/STATE — moves to "assumptions")
                            └─ LiveMetrics (suggest_pressed/ask_submitted →
                                answer_visible, per provider)
                                  │  LiveAssistSnapshot.v2* fields
                          AppState+LiveAssist (liveAutoSuggest, context
                          picker) → LiveAssistPanel (button, in-progress
                          state, answer + "known"/"context"/"assumptions"
                          lines, Ask field, context row)
```

- **`ManualFileContextProvider`** (plan §7.3) implements the `LiveContextProvider`
  seam already reserved in V1: one `.md`/`.txt` file picked via `NSOpenPanel`
  per meeting, read once, capped at ≈24k chars (a `truncated` flag surfaces a
  UI note), kept in memory only — never written to disk, never sent with the
  per-turn V1 semantic call. A future V3 retrieval provider can implement the
  same `LiveContextProvider` protocol without touching `LiveCopilotEngine` or
  the panel's call sites.
- **Output contract** (`{answer, known_from_meeting, from_context,
  assumptions, confidence}`) is shared by both flows and is OpenAI
  strict-mode-safe the same way `semanticJSONSchema` is (a unit test —
  `LiveCopilotSchemaStrictModeTests` — recursively validates every JSON
  Schema this codebase ships against strict mode: `additionalProperties:
  false` on every object, every property listed in `required`).
- **`liveAutoSuggest`** (default **off**) makes `AppState` press "Suggest
  Answer" automatically the moment a genuinely new question is detected
  (tracked by question id, fires at most once per question) — purely a
  convenience on top of the same manual `suggestAnswer(questionID:)` call the
  panel's button makes.
- **Persistence**: `<session>/live/assist.jsonl` gets one line per completed
  V2 request — question, answer, provider, latency, confidence, and the
  context file's **name only** (never its content); `LiveCopilotPersistence`
  has no code path that can write file content there.

V2 does not add embeddings, an index, or a vector DB — "context" is always
exactly the one file the user picked, in full (bounded), never retrieved or
ranked.

## Constraints and non-goals

- Do not redesign the provider abstraction when adding a provider.
- Do not alter recording, audio capture, sync, or MLX Whisper behavior for a
  notes-only change.
- Do not add Ollama, a persistent background service, RAG, embeddings, vector
  databases, or a generic LLM framework for this product path.
- Keep model downloads/runtime management app-owned and explicit.

## Security notes

- Provider API keys live in the Keychain; a failed Keychain write is reported
  to the user instead of being ignored. The Gemini key is sent in the
  `x-goog-api-key` header, never in a URL.
- Meeting content is sent only to the providers the user selected.

## Testing

`make test` runs the Swift Testing suite — `tests/MeetGistKitTests` for
MeetGistKit and `tests/MeetGistAppTests` for the `MeetGistApp` executable
target (`@testable import MeetGistApp`; SPM can test an executable target the
same way) — and the Python unit tests for the workers and
`scripts/sync_tracks.py`. `AppState`'s processing lifecycle (generation-token
guarded completions, settings persistence, key/notes readiness) is covered in
`tests/MeetGistAppTests` via the constructor injection points documented on
`AppState.init` (UserDefaults instance, initial output dir, key lookup
closure, local-runtime manager instances, `pipelineFactory`/
`notesWriterFactory`), which keep tests from touching the real UserDefaults
domain, `~/Documents/meetgist`, Keychain, or Application Support. Real
recording (`SessionRecorder`/ScreenCaptureKit) and OS permissions are not
covered by any test and need manual verification. It adds the extra framework
flags Swift Testing needs under the Command Line Tools. A clean SwiftPM build of
`MeetGistApp` works with macOS 27 Command Line Tools: the pinned local
`Vendor/KeyboardShortcuts` copy omits preview-only macros, and app state uses
the SDK's `SwiftUI.State` property wrapper through `CompatibleState`, avoiding
the `SwiftUIMacros` host plugin missing from CLT. The signed `.app` build still
requires full Xcode. There is no CI; run `make test`
and `swift build` locally before pushing. Live Assist adds
`tests/MeetGistKitTests/LiveAssistSessionTests.swift` (the orchestrator, with
fake audio sources/transcriber/LLM) and
`tests/MeetGistAppTests/AppStateLiveAssistTests.swift` (the isolation
contract, plus V2 wiring: auto-suggest on/off, manual context forwarding,
context cleared on a new recording) to the normal suite, plus an env-gated
`tests/MeetGistKitTests/LiveCopilotBenchmarkTests.swift`
(`MEETGIST_LIVE_BENCH=1`, real audio/model/network — never run by `make
test` or CI) that produces the measurements in
`docs/live-copilot-plan.md` §13. V2 adds its own V1-parity test coverage: V2
scheduling/cancellation/staleness cases in
`tests/MeetGistKitTests/LiveCopilotEngineTests.swift`, and dedicated suites
in `tests/MeetGistKitTests/LiveCopilotV2Tests.swift` (prompt builder, answer
parser, post-check, `ManualFileContextProvider`) and
`LiveCopilotSchemaStrictModeTests` (a generic OpenAI-strict-mode validator
run against every JSON Schema this codebase ships, `semanticJSONSchema` and
`answerJSONSchema` alike — the exact class of bug P4 found by hand).

## Related documents

- [AGENTS.md](../AGENTS.md) — source priority and engineering guardrails.
- [offline-transcription-plan.md](offline-transcription-plan.md) — current
  Offline MLX Whisper v1 implementation notes.
- [dual-file-sync-engineering-plan.md](dual-file-sync-engineering-plan.md) —
  focused sync design work.
- [design.md](design.md) — UI visual system.
