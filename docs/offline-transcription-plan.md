# Offline MLX Whisper v1 — Implementation Notes

> Status: implemented. This document replaces the earlier proposal-style plan.
> The cross-feature architecture is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Scope

Offline transcription runs MLX Whisper locally on Apple Silicon Macs. It is a
transcription provider only: it creates the normal `transcript.md`, after which
the independently selected notes provider generates minutes or summaries.

The v1 model is `mlx-community/whisper-large-v3-mlx`; its runtime/model version
is pinned by the implementation rather than selected dynamically.

The implementation deliberately does not change recording, audio capture,
audio-sync behavior, cloud providers, or the notes output contract.

## Current design

- The app manages a pinned MLX Whisper runtime/model in Application Support
  under `OfflineWhisper/v1`.
- `OfflineJobCoordinator` permits one local transcription worker at a time.
- Audio is processed in core chunks with a small overlap. Each completed part
  is committed before the next part begins.
- `OfflineJobStore` saves per-meeting job state and part results under the
  meeting's `transcription/` directory. A paused or interrupted job resumes
  from the committed checkpoint rather than reprocessing completed audio.
- Progress uses completed work and rolling processing time. Model execution is
  isolated in `Resources/offline_worker.py`.
- Starting a recording has priority: active local transcription is stopped
  safely before capture proceeds.

## Code map

| Responsibility | Location |
| --- | --- |
| Runtime setup and model lifecycle | `Sources/MeetGistKit/OfflineRuntimeManager.swift` |
| Job scheduling/cancellation | `Sources/MeetGistKit/OfflineJobCoordinator.swift` |
| Checkpoints and persisted progress | `Sources/MeetGistKit/OfflineJobStore.swift` |
| MLX Whisper inference | `Sources/MeetGistKit/Resources/offline_worker.py` |
| App lifecycle and post-transcription notes step | `app/Sources/AppState/AppState+Processing.swift` |

## Operating invariants

- `transcript.md` remains the canonical transcript. Checkpoint files are
  recovery artifacts only.
- A selected local provider never silently uses a cloud provider.
- Local Whisper and Local Qwen Notes are separate capabilities and runtimes.
- Keep the existing cloud pipeline unchanged unless a cloud-specific task says
  otherwise.
- Preserve cancellation, pause/resume, and cleanup behavior when changing the
  offline path.

## Intentional v1 limits

- No live transcription during recording.
- No parallel local Whisper jobs.
- No automatic model fallback, RAG, vector database, or generic local-LLM
  layer.
- Whisper progress is stored per meeting; it does not maintain a global
  `last-run-metrics.json` like Local Qwen Notes.

## Change checklist

For offline-transcription changes, verify an interrupted job can resume, a
completed job still yields the usual transcript, notes selection remains
independent, and a new recording safely takes priority. Keep changes scoped to
this path unless the request explicitly expands scope.
