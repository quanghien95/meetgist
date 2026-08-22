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
| App lifecycle and user flows | `app/Sources/AppState.swift` |
| Settings and meeting UI | `app/Sources/SettingsView.swift`, `app/Sources/Library`, `app/Sources/MeetingDetailView.swift` |
| Recording and audio capture | `Sources/MeetGistKit/Recorder.swift`, `SessionRecorder.swift`, `AudioTools.swift` |
| Meeting files and list actions | `Sources/MeetGistKit/MeetingStore.swift` |
| Provider assembly and output contracts | `Pipeline.swift`, `Provider.swift`, `Prompts.swift`, `NotesTemplates.swift` |
| Cloud providers | `GeminiClient.swift`, `OpenAIClient.swift` |
| Offline MLX Whisper transcription | `OfflineJobCoordinator.swift`, `OfflineJobStore.swift`, `OfflineRuntimeManager.swift`, `Resources/offline_worker.py` |
| Local Qwen notes | `LocalNotesRuntimeManager.swift`, `QwenMLXNotes.swift`, `Resources/qwen_notes_worker.py` |
| Apple on-device notes | `AppleFoundationModelsNotes.swift` |

## Architecture invariants

- Keep recording/audio capture, transcription, and notes generation separate.
  Do not change recording, sync, or audio behavior unless the task requires it.
- `transcript.md` is the canonical input to the notes stage. Preserve the
  existing `polished.md` and `summary.md` output contract and UI.
- Transcription and notes each have their own provider selection. Local Whisper
  is transcription-only; Local Qwen is notes-only.
- A local provider must never silently fall back to a cloud provider.
- Preserve existing cloud-provider behavior. Prefer the smallest coherent
  extension over redesigning provider abstractions.
- Local runtimes are app-managed and isolated from meeting data:
  `OfflineWhisper/v1` and `LocalNotes/Qwen3-8B/v1` under Application Support.
- Recording has priority over local ML work. Stop or cancel local workers safely
  before starting capture.

## Critical flows

- **FLOW-1 — Recording:** capture audio and timing/sync data into a meeting
  directory.
- **FLOW-2 — Cloud pipeline:** selected cloud transcription/notes providers run
  through the existing composed pipeline.
- **FLOW-3 — Offline transcription:** MLX Whisper writes resumable per-meeting
  state and transcript parts, then produces `transcript.md`.
- **FLOW-4 — Notes:** an existing transcript is sent only to the selected notes
  provider, which writes the established notes outputs.
- **FLOW-5 — Local Qwen setup/run:** the app installs the pinned runtime/model,
  runs a local MLX-LM worker, and stores its latest job metrics separately.

## Working protocol

Before changing code, read the relevant architecture document and inspect the
owner code above. Check provider, persistence, cancellation, and UI impact.
Follow existing patterns and make the smallest change that fully solves the
request. Do not introduce a daemon, RAG/vector store, generic LLM framework,
or new persistence layer without an approved architecture decision.

After changing code, run focused tests or syntax checks appropriate to the
change, inspect the diff, and report unverified items. For API, schema, or
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
- A local Swift toolchain/SDK mismatch can block `swift test`; never report it
  as passing unless it actually ran.

## Definition of done

Deliver scoped code, focused tests or checks, error and cancellation handling,
preserved cloud behavior, and updated documentation when behavior changes.
Report assumptions, limitations, and any validation that could not run.
