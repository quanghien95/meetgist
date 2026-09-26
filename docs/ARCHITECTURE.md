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
             │     └── Offline MLX Whisper worker
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

Offline Whisper additionally stores resumable state and committed part results
under the meeting's `transcription/` directory. These are job-recovery data,
not a replacement for the canonical transcript.

## Provider boundaries

There are two independent provider selections:

| Capability | Providers | Boundary |
| --- | --- | --- |
| Transcription | Existing cloud providers, Offline MLX Whisper | Produces `transcript.md` |
| Notes / summary | Existing cloud providers, Apple Foundation Models, Local Qwen MLX-LM, Codex CLI | Consumes `transcript.md`; produces existing notes outputs |

The composed cloud pipeline remains intact for existing cloud behavior. Local
workers are explicit selections and must never silently fall back to cloud.
Local Whisper does not generate notes; Local Qwen does not transcribe audio.
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
stdout/stderr is stored as `postprocess-output.md` in the meeting directory.

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

### Cloud processing

The existing `Pipeline`/`Provider` composition invokes the selected cloud
providers and preserves their previous transcript-to-notes behavior.

### Offline MLX Whisper transcription

`OfflineJobCoordinator` schedules a single resumable Whisper job.
`OfflineJobStore` persists progress and committed parts; `offline_worker.py`
does MLX Whisper inference. Completion writes the regular transcript contract,
after which the normal notes stage can run.

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
└── LocalNotes/Qwen3-4B/v1/
    └── last-run-metrics.json
```

Qwen's metric file describes only the most recent local Qwen notes job. It
includes total elapsed time, wall-clock time, model load, reliable MLX
prefill/decode timing, token counts/rate, peak memory, source chunk count, and
a breakdown of map/reduce/final LLM call counts (so a direct-context run and a
map/reduce fallback run are distinguishable) when available. Whisper uses
per-meeting job state and part timing instead.

Recording has priority over local processing. The app safely stops or cancels
the relevant local worker before capture begins; local work must support normal
cancellation and failure reporting.

## Constraints and non-goals

- Do not redesign the provider abstraction when adding a provider.
- Do not alter recording, audio capture, sync, or MLX Whisper behavior for a
  notes-only change.
- Do not add Ollama, a persistent background service, RAG, embeddings, vector
  databases, or a generic LLM framework for this product path.
- Keep model downloads/runtime management app-owned and explicit.

## Related documents

- [AGENTS.md](../AGENTS.md) — source priority and engineering guardrails.
- [offline-transcription-plan.md](offline-transcription-plan.md) — current
  Offline MLX Whisper v1 implementation notes.
- [dual-file-sync-engineering-plan.md](dual-file-sync-engineering-plan.md) —
  focused sync design work.
- [design.md](design.md) — UI visual system.
