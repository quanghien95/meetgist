# Post-meeting Offline MLX Whisper v1 Plan

## Objective

Ship the smallest reliable offline transcription extension for Apple Silicon
Macs:

```text
Record meeting
-> stop and finalize system.m4a + mic.m4a
-> run MLX Whisper locally on Apple Silicon
-> transcribe fixed chunks sequentially
-> persist each completed chunk
-> resume after interruption
-> merge transcript
-> optionally generate Meeting Minutes
```

This is a post-meeting feature. Recording code and the existing synchronization
implementation remain untouched.

## Mandatory requirements

1. Do not modify `Recorder.swift`, `SessionRecorder.swift`, or audio capture
   and finalization behavior.
2. Whisper must never run while recording.
3. Use only `mlx-whisper` with `mlx-community/whisper-large-v3-mlx`.
4. Transcribe `system.m4a` and `mic.m4a` separately.
5. Run one local job and one chunk at a time.
6. Load the model once per job.
7. Atomically persist completed chunks.
8. Resume from committed chunks instead of starting at 00:00.
9. Show progress and ETA.
10. Keep transcription and Meeting Minutes as separate stages and provider
    choices.
11. Preserve existing Gemini, OpenAI, and Groq behavior.
12. Offline Local Whisper v1 requires Apple Silicon; cloud providers remain
    available on unsupported Macs.
13. Never delete canonical meeting audio during transcription, retry, cancel,
    runtime removal, or recovery.

## Deliberately deferred

- Live transcription.
- A generic local-backend interface or plugin architecture.
- Parallel jobs, parallel chunks, priorities, or a persistent queue database.
- Adaptive chunking, model fallback, and MLX tuning.
- Ranged PyAV/M4A seeking.
- Content hashes, source fingerprints, artifact migrations, and
  `metrics.jsonl`.
- Drift correction beyond an existing track offset.
- Diarization, speaker identification, and word-level timestamps.
- Offline-specific library badges, menu-bar controls, HUD notifications, or a
  global jobs screen.

Add these only after real v1 usage proves they are needed.

## Fixed v1 decisions

| Item | Decision |
| --- | --- |
| Engine | Direct Python `mlx-whisper` worker |
| Model | `mlx-community/whisper-large-v3-mlx` |
| Hardware | Apple Silicon GPU through MLX |
| Core chunk length | 5 minutes |
| Overlap | 5 seconds |
| Track order | system, then microphone |
| Concurrency | one job, one chunk |
| Audio passed to ASR | mono 16 kHz |
| Sync mapping | `master_time = local_time + offset`, `scale = 1` |

Language and optional technical vocabulary are user settings. The app does not
silently change model or performance settings.

## Minimal architecture

```text
AppState / existing post-stop flow
        |
OfflineJobCoordinator
        |
Python MLX Whisper worker
        |
state.json + parts/*.json -> transcript.md
```

`OfflineJobCoordinator` owns at most one worker process. It directly starts the
bundled Python worker; do not add an `OfflineTranscriptionBackend` abstraction
in v1.

The worker owns audio decoding, chunking, inference, and part-file commits.
Swift owns runtime setup, job lifecycle, process control, and UI state.

## Runtime setup

The app owns an isolated Python environment and model cache under its Application
Support directory. Do not use or modify the user's shell Python environment.

Pin:

- CPython 3.11.
- The exact `mlx-whisper` and `mlx` versions.
- Required Python dependencies.
- The `mlx-community/whisper-large-v3-mlx` model revision.

An ordinary transcription run uses installed local files and must not download
anything.

The complete runtime state model is:

```text
Not Installed
Installing
Ready
Failed
```

The only actions are `Install`, `Retry`, and `Remove`. Removal affects only
the app-owned runtime/model cache, never meeting files. Do not build a general
runtime migration or version-management platform in v1.

## Job state and persistence

### States

Use only:

```text
pending
transcribing
paused
completed
failed
canceled
```

A crash leaves no extra persisted state such as `interrupted`. On the next
launch, convert an unfinished `transcribing` job to resumable `pending` or
`failed`.

### Files

Each session stores:

```text
transcription/
  state.json
  parts/
    system-0000.json
    system-0001.json
    mic-0000.json
    ...
```

Committed part files are the source of truth. `state.json` is current status and
a progress cache. Do not add a queue file or metrics log.

### Minimal `state.json`

```json
{
  "schema_version": 1,
  "job_id": "offline-20260821-001",
  "session_id": "2026-08-21-meeting",
  "status": "transcribing",
  "config_id": "mlx-whisper-large-v3-v1",
  "config": {
    "engine": "mlx-whisper",
    "model": "mlx-community/whisper-large-v3-mlx",
    "language": "auto",
    "vocabulary": "MeetGist, Swift",
    "chunk_seconds": 300,
    "overlap_seconds": 5
  },
  "tracks": {
    "system": { "duration_seconds": 5400.0 },
    "mic": { "duration_seconds": 5398.4 }
  },
  "progress": {
    "processed_seconds": 2400.0,
    "total_seconds": 10798.4,
    "current_track": "system",
    "current_chunk": 8,
    "rolling_rtf": 0.42,
    "eta_seconds": 3527
  },
  "last_error": null
}
```

### Minimal part file

```json
{
  "schema_version": 1,
  "job_id": "offline-20260821-001",
  "session_id": "2026-08-21-meeting",
  "config_id": "mlx-whisper-large-v3-v1",
  "track": "system",
  "chunk_index": 8,
  "core_start_seconds": 2400.0,
  "core_end_seconds": 2700.0,
  "processing_seconds": 124.6,
  "segments": [
    {
      "start_seconds": 2412.2,
      "end_seconds": 2415.8,
      "text": "Example segment"
    }
  ]
}
```

A part is reusable when it parses and its schema, job/session ID, config ID,
track, chunk index, and core interval match the current job. No hashes,
fingerprints, or migration framework are required.

### Atomic commit and recovery

For each completed chunk:

```text
write part.json.tmp
-> flush and fsync
-> atomic rename to part.json
-> atomically update state.json
```

On resume:

1. Delete abandoned temporary files.
2. Scan and validate committed parts.
3. Rebuild progress from those parts.
4. Continue at the first missing chunk.

If the app or worker dies during a chunk, only that uncommitted chunk may be
repeated.

## Audio and chunk processing

Process one track at a time:

1. Decode the complete track.
2. Resample it to mono 16 kHz in memory.
3. Slice five-minute logical core chunks with five seconds of audio overlap.
4. Apply a lightweight frame-energy speech/silence guard to each audio slice.
5. Skip ASR and commit an empty part when there is no meaningful speech.
6. Transcribe speech chunks sequentially with the already-loaded MLX model.
7. Commit each result before continuing.
8. Release the decoded track before opening the next track.

For core interval `[start, end)`, transcribe:

```text
[max(0, start - 5s), min(trackDuration, end + 5s))
```

Convert segment timestamps back to absolute track-local time. Keep a segment
only when its midpoint falls inside the chunk's core interval. This gives
deterministic overlap de-duplication.

A missing, empty, silent, or unreadable track produces a warning; transcribe the
other valid track. Fail only if neither track is usable. The silence guard is an
energy test, not a phrase blacklist or a general VAD subsystem.

Whole-track decoding is intentional. Measure memory on 90- and 120-minute
recordings on the target M1 Pro 16 GB machine. Add ranged decoding later only if
those measurements show a real problem.

## Progress and ETA

Persist progress only after a part is committed:

```text
overall progress =
  committed core seconds across valid tracks
  / total seconds across valid tracks

RTF = recent processing seconds / recent committed core seconds
ETA = remaining core seconds * rolling RTF
```

The UI may show in-memory movement for the active chunk, but recovery trusts only
committed parts. Show ETA after enough completed work exists for a useful
estimate.

## Lifecycle behavior

### After recording stops

The existing stop flow finalizes `system.m4a` and `mic.m4a`. Only after it
returns may offline work begin.

When Offline transcription and auto-transcribe are enabled:

1. Confirm runtime state is `Ready`.
2. Create or recover the session job.
3. Start at the first missing chunk.

If setup is not ready, keep the audio and expose a resumable setup-required
failure.

### When a new recording starts

Before capture begins:

```text
request worker stop
-> wait for confirmed process exit
-> keep committed parts
-> mark the job pending
-> start recording
```

The active, uncommitted chunk may be discarded. Recording always has priority.
The unfinished session remains available to Resume after recording.

### Pause, cancel, retry, and relaunch

- `Pause`: stop the worker safely, preserve parts, set `paused`.
- `Cancel`: stop the worker safely, preserve parts, set `canceled`.
- `Resume`: continue from the first missing valid part.
- `Retry`: preserve valid parts and continue after the error is resolved.
- Relaunch: scan session folders, repair stale `transcribing` state, and show
  `Resume`; do not silently start heavy work.
- `Re-transcribe`: after explicit confirmation, remove only `transcription/`
  and `transcript.md`, then start a fresh job. Preserve both audio tracks, sync
  metadata, and Meeting Minutes files.

Maintain only a simple ordered in-memory list of incomplete session folders and
one active worker. Reconstruct the list by scanning sessions on launch.

## Sync, merge, and Meeting Minutes

Reuse current sync metadata without changing its capture or generation.

- Apply the existing track offset when available.
- If `sync_map.json` is absent but native `capture_timing.json` contains both
  host-clock start anchors, materialize the existing coarse offset map before
  merging. This connects the native recording path without changing capture.
- Use `scale = 1`.
- If no usable offset exists, use zero and emit a warning.

```text
meeting_time = track_local_time + track_offset
```

Merge accepted system and microphone segments by meeting time and write the
canonical `transcript.md` using the repository's current output convention.

Meeting Minutes is a later, optional action that consumes `transcript.md`.
It uses the independently selected notes provider. Choosing Offline Whisper for
transcription must not change the configured Gemini/OpenAI/Groq minutes path.

## UI scope

The new controls must look native to the current app. Reuse the existing
Settings groups, typography, spacing, colors, status pills, progress views,
button styles, and Meeting Detail tabs. Do not introduce a new visual language.

### Settings only

Extend the current scrollable grouped Settings UI with:

- Transcription provider: Cloud or Offline/Local Whisper.
- Runtime/model status and `Install`, `Retry`, or `Remove`.
- Fixed model readout: `MLX Whisper · Large V3 · Apple Silicon`.
- Language.
- Optional technical vocabulary.
- Auto-transcribe toggle.

Keep the notes/minutes provider visibly separate. Show install progress and
errors inline in the existing group, not in a new setup window.

### Meeting Detail only

Use the existing processing/status area and current Summary, Minutes, and
Transcript tabs. Show:

```text
Local transcription       63%
System · Chunk 14
System              Completed
Microphone                 26%
ETA                      8 min

[Pause] [Cancel]
```

Show `Resume` or `Retry` when appropriate. Reuse existing step/status and
button components. A completed job also exposes `Re-transcribe` behind an
explicit confirmation. Put completed output in the existing Transcript tab,
then enable the existing Generate Minutes action.

Do not add v1 offline UI to:

- Meeting library rows.
- Menu-bar recording UI.
- Recording HUD/compact UI.
- Global navigation or a new job-management screen.

## Minimal code scope

Expected additions:

```text
OfflineJobCoordinator.swift
OfflineRuntimeManager.swift
OfflineJobStore.swift
offline_worker.py
offline requirements lock file
```

Expected integration points:

- `Package.swift`: bundle the worker and locked requirements.
- `Provider.swift` / `Pipeline.swift`: select the direct offline path without
  changing current cloud paths.
- `AppState.swift`: own coordinator lifecycle and stop it before recording.
- Current Settings and Meeting Detail views.
- Existing localization resources.

Do not modify the recorder or current sync implementation.

## Implementation order

1. Add the pinned app-owned runtime setup and minimal JSON contracts.
2. Implement the direct worker, whole-track decode, fixed chunking, and atomic
   parts using a fake model in tests.
3. Add coordinator process control, recovery, progress, and recording exclusion.
4. Add offset-only merge and `transcript.md` generation.
5. Add Settings and Meeting Detail controls using current UI components.
6. Verify cloud transcription and separate Meeting Minutes behavior.

## Verification

### Automated tests

- Fixed five-minute chunks and five-second overlap.
- Midpoint overlap ownership.
- Model loaded once per job.
- Tracks and chunks processed sequentially.
- Silence guard skips silent input without calling MLX Whisper.
- Atomic commit and abandoned temporary-file recovery.
- Crash after several chunks, then reuse committed parts.
- First-missing-chunk resume with missing or corrupt parts.
- Progress, rolling RTF, and ETA.
- Missing/silent/corrupt track handling.
- Offset-only two-track merge.
- Worker shutdown completes before recording starts.
- Offline transcription provider remains independent of the minutes provider.
- Existing Gemini/OpenAI/Groq paths remain unchanged.

Python worker tests use a fake model and do not download dependencies or models.

### Required acceptance scenario

```text
record a 90-minute meeting
-> stop and finalize both tracks
-> local transcription begins
-> terminate the app at about 50%
-> reopen the app
-> open the meeting and select Resume
-> verify committed chunks are reused
-> transcription reaches 100%
-> transcript.md is generated
-> Generate Minutes succeeds from transcript.md
```

The completed target-machine benchmark selected MLX Whisper Large V3 with suite
RTF about `0.222`, local-recording RTF `0.173` (`46.6s` for `270s`), peak RSS
about `1.54 GiB`, Vietnamese WER/CER `14.3%`/`9.7%`, and mixed-language WER/CER
`14.9%`/`11.5%` on an M1 Pro 16 GB. Add ranged decoding later only if real
long-meeting usage shows a memory problem.

## Done criteria

v1 is done when the acceptance scenario passes reliably and:

- Recording and existing sync code are unchanged.
- Whisper never overlaps recording.
- One model instance serves one sequential job.
- Completed chunks survive pause, cancel, crash, and relaunch.
- Progress and ETA appear in Meeting Detail.
- Final merged `transcript.md` is usable by Generate Minutes.
- Canonical audio is preserved.
- Existing cloud behavior passes regression checks.
- Offline UI exists only in current Settings and Meeting Detail surfaces and
  matches the current app UI.

## Implementation notes (2026-08-22)

- `Install` downloads one pinned CPython 3.11.16 Apple Silicon archive, verifies
  its SHA-256, installs the exact locked MLX Whisper packages, and downloads the
  pinned `mlx-community/whisper-large-v3-mlx` revision into MeetGist's
  Application Support folder.
  Ordinary transcription uses only those local files.
- Worker shutdown first requests a cooperative stop. If MLX Whisper is still
  inside native inference after a two-second grace period, the coordinator
  force-stops the child process. Atomic part commits preserve every completed
  chunk and the current uncommitted chunk is retried later, so recording is not
  delayed by local inference.
- Every entry point into local transcription rejects work while a recorder is
  active. The existing cloud pipeline keeps its previous lifecycle behavior.
- Apple On-Device Meeting Notes split long transcripts into context-safe chunks,
  extract faithful facts in independent sessions, recursively condense those
  facts, and only then generate the final Minutes/Summary in a fresh session.
- Python and Swift validate the complete reusable-part contract, including each
  segment, so a parseable but malformed part is reprocessed instead of poisoning
  every retry.
- Runtime install progress is stage-based (runtime, packages, model), rather
  than byte-accurate. Job progress and ETA remain based only on committed audio
  core seconds as specified above.
- The benchmark decision is final for v1: no other local ASR engine, engine
  selector, or fallback is implemented. The real long-meeting
  terminate/reopen acceptance scenario still requires a representative meeting;
  no ranged-decoding work was added preemptively.
