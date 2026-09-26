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

### Cloud processing

The existing `Pipeline`/`Provider` composition invokes the selected cloud
providers and preserves their previous transcript-to-notes behavior.
`MeetingProcessor.process` runs it as two stages and writes `transcript.md`
as soon as transcription succeeds, before the notes provider is called — a
notes failure (quota, network, bad model name) leaves the transcript on disk
and the meeting can be retried from Generate, the same contract the offline
path already had.

### Offline transcription (MLX Whisper, Qwen3-ASR)

Each offline engine has its own runtime manager (`OfflineRuntimeManager`,
`Qwen3ASRRuntimeManager`) and its own `OfflineJobCoordinator`, which schedules
a single resumable job running the bundled worker (`offline_worker.py` /
`offline_worker_qwen.py`). `OfflineJobStore` persists progress and committed
parts; part IDs are namespaced by engine+model so switching engines never
reuses incompatible output. Completion writes the regular transcript contract,
after which the normal notes stage can run.

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
revision. Each writes a `ready.json` marker recording those versions.

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

`make test` runs the Swift Testing suite (`tests/MeetGistKitTests`, MeetGistKit
only — `app/Sources` has no test target) and the Python unit tests for the
workers and `scripts/sync_tracks.py`. It adds the extra framework flags Swift
Testing needs under the Command Line Tools. Caveat: a *clean* build of the
`MeetGistApp` target needs full Xcode, because the `KeyboardShortcuts`
dependency (every 2.x release) contains `#Preview` blocks whose
`PreviewsMacros` plugin ships only with Xcode. There is no CI; run `make test`
and `swift build` locally before pushing.

## Related documents

- [AGENTS.md](../AGENTS.md) — source priority and engineering guardrails.
- [offline-transcription-plan.md](offline-transcription-plan.md) — current
  Offline MLX Whisper v1 implementation notes.
- [dual-file-sync-engineering-plan.md](dual-file-sync-engineering-plan.md) —
  focused sync design work.
- [design.md](design.md) — UI visual system.
