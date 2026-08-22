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
| Notes / summary | Existing cloud providers, Apple Foundation Models, Local Qwen MLX-LM | Consumes `transcript.md`; produces existing notes outputs |

The composed cloud pipeline remains intact for existing cloud behavior. Local
workers are explicit selections and must never silently fall back to cloud.
Local Whisper does not generate notes; Local Qwen does not transcribe audio.

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
model (`mlx-community/Qwen3-8B-4bit`, with the revision pinned in code).
`QwenMLXNotes` runs `qwen_notes_worker.py` as an app-managed local process.
After setup, generation is offline. The worker performs one model load per
Generate/Regenerate job, then accumulates chunk/reduce timings.

## Runtime storage and lifecycle

App-managed runtimes are kept outside meeting data in Application Support:

```text
MeetGist/
├── OfflineWhisper/v1/
└── LocalNotes/Qwen3-8B/v1/
    └── last-run-metrics.json
```

Qwen's metric file describes only the most recent local Qwen notes job. It
includes total elapsed time, model load, reliable MLX prefill/decode timing,
token counts/rate, peak memory, and source chunk count when available. Whisper
uses per-meeting job state and part timing instead.

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
