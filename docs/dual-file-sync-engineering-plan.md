> **Status (2026-06-24):** Phases 1–2 are IMPLEMENTED in this repo —
> `capture_timing.json` is written by `Sources/meetgist/{Recorder,main}.swift`,
> `scripts/sync_tracks.py` produces `sync_map.json` + `sync_report.md` and is
> hooked into `postprocess.py`; pure tests in `tests/test_sync_tracks.py`.
> Phases 3–5 (transcript-timestamp mapping, AVAudioEngine mic buffers, click/chirp
> verification) are deferred.

# Dual-file audio sync engineering plan

## Purpose

Design and implement synchronization for meetgist's existing dual-file recording
model:

- `system.m4a`: ScreenCaptureKit system audio.
- `mic.m4a`: microphone audio.

The goal is to keep the two files as canonical source artifacts, then create an
explicit sync model in post-processing so transcripts, playback, and exports can
share one master timeline.

This plan intentionally does not require a single multi-track `AVAssetWriter` in
the first implementation. A shared writer can be revisited later, but the
dual-file approach is easier to debug, retry, chunk, and transcribe.

## Current repo facts

- `Sources/meetgist/main.swift` creates one session directory and records:
  - `system.m4a`
  - `mic.m4a`
- `Sources/meetgist/Recorder.swift` currently implements:
  - `SystemAudioRecorder`: ScreenCaptureKit audio sample buffers appended to an
    `AVAssetWriter`.
  - `MicRecorder`: `AVAudioRecorder` writing a separate AAC file.
- `scripts/postprocess.py` is launched after stop and treats the session folder
  as the unit of work.

## Problem statement

Starting and stopping both recorders in the same user action is not enough for
sample-accurate sync.

Reasons:

- The first real audio sample can arrive after the API's `start()` call.
- The last real audio sample can differ from the API's `stop()` call because of
  buffering and encoder flush.
- The mic device clock and system audio clock can drift even when both are
  configured as 48 kHz.
- AAC containers can include encoder delay/padding, so file duration is not
  always a perfect proxy for audio timeline duration.

The engineering target is therefore:

1. Capture enough timing metadata during recording.
2. Build a sync map in post-processing.
3. Use that sync map to transform transcript timestamps and optionally render
   aligned audio files.

## Non-goals for the first implementation

- Do not replace the dual-file architecture with a single multi-track writer.
- Do not rewrite the full recording engine.
- Do not require real-time resampling during capture.
- Do not block transcription if sync confidence is low; emit warnings and still
  process the raw files.
- Do not remove the current `system.m4a` / `mic.m4a` artifacts.

## Deliverables

### 1. Recording-time sidecar metadata

Add a recording metadata sidecar in every session folder:

```text
session/
  system.m4a
  mic.m4a
  capture_timing.json
```

Minimum schema:

```json
{
  "schema_version": 1,
  "created_by": "meetgist",
  "session": {
    "session_dir": "/absolute/path/to/session",
    "record_command_start_host_ns": 0,
    "stop_requested_host_ns": 0,
    "stop_completed_host_ns": 0
  },
  "system": {
    "file": "system.m4a",
    "requested_start_host_ns": 0,
    "stream_started_host_ns": 0,
    "first_buffer_host_ns": 0,
    "first_buffer_pts_seconds": 0.0,
    "last_buffer_host_ns": 0,
    "last_buffer_pts_seconds": 0.0,
    "buffers_appended": 0,
    "sample_rate": 48000,
    "channels": 2,
    "writer_status": "completed",
    "error": null
  },
  "mic": {
    "file": "mic.m4a",
    "requested_start_host_ns": 0,
    "record_started_host_ns": 0,
    "stop_called_host_ns": 0,
    "sample_rate": 48000,
    "channels": 1,
    "recorder_status": "completed",
    "error": null
  }
}
```

Notes:

- Use a monotonic clock such as `DispatchTime.now().uptimeNanoseconds` for
  `*_host_ns`.
- For the current `AVAudioRecorder` mic implementation, first sample timestamps
  are not available. Record the best available start/stop anchors now.
- If/when mic capture moves to `AVAudioEngine` tap or
  `AVCaptureAudioDataOutput`, extend the mic metadata with first/last buffer
  host time, PTS, and frame counts.

### 2. Sync map generation

Add a post-processing sync stage:

```text
session/
  sync_map.json
  sync_report.md
```

Minimum `sync_map.json` schema:

```json
{
  "schema_version": 1,
  "master": "system",
  "system": {
    "file": "system.m4a",
    "offset_seconds": 0.0,
    "scale": 1.0
  },
  "mic": {
    "file": "mic.m4a",
    "offset_seconds": 0.012,
    "scale": 0.99994
  },
  "confidence": "coarse",
  "warnings": []
}
```

Interpretation:

```text
master_time_seconds = offset_seconds + scale * local_track_time_seconds
```

For v1:

- Use system audio as the master timeline.
- Estimate initial offset from timing metadata.
- Estimate scale from file durations and/or timing anchors.
- Mark confidence as:
  - `none`: missing metadata or missing file.
  - `coarse`: current `AVAudioRecorder` mic anchors only.
  - `buffer`: both tracks have first/last buffer timing.
  - `verified`: cross-correlation or explicit test signal confirms the map.

### 3. Transcript timestamp mapping

Update the transcription pipeline so each track can be transcribed on its local
timeline, then mapped into the session master timeline using `sync_map.json`.

Expected behavior:

- Raw ASR timestamps remain preserved in intermediate artifacts.
- Final `transcript.md` uses master timeline timestamps.
- `postprocess_meta.json` records that sync mapping was applied and includes the
  sync confidence.

This is preferred over always rendering new audio because it avoids unnecessary
audio degradation.

### 4. Optional aligned audio render

Add an optional command, not required for every run:

```bash
scripts/sync_tracks.py --render <session_dir>
```

Possible outputs:

```text
session/
  system.synced.wav
  mic.synced.wav
  monitor_mix.synced.m4a
```

This is only needed for synchronized playback, debugging, or exports. The
transcription path should be able to use timestamp mapping alone.

## Suggested implementation phases

### Phase 1: metadata only

Files likely to change:

- `Sources/meetgist/Recorder.swift`
- `Sources/meetgist/main.swift`

Tasks:

1. Add lightweight metadata structs.
2. Capture host-time anchors around:
   - record command start
   - system recorder requested start
   - system stream started
   - system first audio buffer
   - system last audio buffer
   - mic recorder requested start
   - mic recorder started
   - stop requested
   - stop completed
3. Write `capture_timing.json` at stop, before launching postprocess.
4. Never fail recording just because metadata writing fails. Log a warning.

Acceptance:

- `swift build -c release` passes.
- A short recording produces `capture_timing.json`.
- Existing `system.m4a`, `mic.m4a`, and postprocess behavior still work.

### Phase 2: sync map script

Files likely to add/change:

- `scripts/sync_tracks.py`
- `scripts/postprocess.py`

Tasks:

1. Add `scripts/sync_tracks.py <session_dir>`.
2. Read `capture_timing.json`.
3. Probe `system.m4a` and `mic.m4a` durations.
4. Compute `sync_map.json`.
5. Write `sync_report.md` with:
   - durations
   - estimated initial offset
   - estimated scale/drift
   - confidence
   - warnings
6. Call the sync stage from `postprocess.py` before transcription.

Acceptance:

- `scripts/sync_tracks.py <session_dir>` exits 0 on a valid session.
- Missing/partial metadata produces warnings, not crashes.
- `postprocess_meta.json` records the sync map path and confidence.

### Phase 3: timestamp mapping

Files likely to change:

- `scripts/postprocess.py`
- any helper that parses ASR timestamps

Tasks:

1. Preserve per-track local ASR timestamps.
2. Apply the affine map from `sync_map.json`.
3. Sort final transcript entries by master timestamp.
4. Record both local and master timestamps in machine-readable metadata if
   available.

Acceptance:

- Final transcript timestamps are monotonic in master time.
- Existing chunked Gemini path still works.
- If sync confidence is `none`, pipeline falls back to current behavior.

### Phase 4: better mic timing

Replace or supplement `AVAudioRecorder` with a sample-buffer-level mic capture
path:

- Option A: `AVAudioEngine` input tap.
- Option B: `AVCaptureSession` + `AVCaptureAudioDataOutput`.

Tasks:

1. Capture mic first/last buffer host time.
2. Capture frame counts.
3. Update `capture_timing.json` confidence from `coarse` to `buffer`.
4. Keep the output file shape unchanged unless there is a strong reason to
   change it.

Acceptance:

- Drift estimates become based on actual mic audio buffers, not just recorder
  start/stop calls.
- 30/60/120 minute tests show stable offset estimation.

### Phase 5: optional verified sync

Add a verification mode for test recordings with a known click/chirp signal.

Tasks:

1. Detect repeated clicks/chirps in both files.
2. Estimate observed offset near the start and end.
3. Compare observed drift to the sync map.
4. Mark confidence as `verified` when within threshold.

## Test plan

### Unit tests

Add tests for pure logic first. These do not need macOS capture permissions.

Recommended test targets:

1. Affine timestamp mapping:
   - input: `offset=0.25`, `scale=0.9999`, local timestamps
   - expected: exact mapped master timestamps within floating tolerance
2. Monotonic sorting:
   - input: mic/system transcript segments interleaved after mapping
   - expected: final transcript sorted by master time
3. Missing metadata:
   - input: no `capture_timing.json`
   - expected: `confidence=none`, warning emitted, no crash
4. Duration mismatch:
   - input: system 7200.0s, mic 7200.5s
   - expected: scale near `7200.0 / 7200.5`

### Synthetic audio tests

Add a deterministic fixture generator:

```bash
scripts/generate_sync_fixture.py --out /tmp/meetgist-sync-fixture \
  --duration 600 \
  --offset-ms 120 \
  --drift-ppm 80
```

Fixture contents:

```text
system.wav
mic.wav
expected_sync_map.json
```

The fixture should create periodic clicks or chirps that make offset/drift easy
to estimate.

Acceptance:

- Estimated offset error <= 10 ms on synthetic fixtures.
- Estimated drift error <= 20 ppm on synthetic fixtures.
- Final mapped click timestamps differ by <= 20 ms at the end of a 10 minute
  fixture.

### Short real capture smoke test

Manual test:

1. Run meetgist for 60 seconds.
2. Play system audio for at least 10 seconds.
3. Speak briefly into the mic.
4. Stop recording.

Expected:

- `system.m4a` exists and is not tiny.
- `mic.m4a` exists and is not tiny unless the meeting is intentionally listen-only.
- `capture_timing.json` exists.
- `sync_map.json` exists.
- `sync_report.md` has no fatal errors.
- Current transcript/summary artifacts still generate.

### Long drift tests

Run three durations:

- 30 minutes
- 60 minutes
- 120 minutes

For each:

1. Play a short click/chirp from system audio every 5 minutes.
2. Let the mic pick up some leakage if possible, or speak/clap near each marker.
3. Stop normally.
4. Run sync report.

Acceptance:

- Pipeline completes without crash.
- Final transcript timestamps are monotonic.
- Sync report includes estimated start offset and end drift.
- End-of-recording alignment target:
  - `verified`: <= 50 ms
  - `buffer`: <= 100 ms expected until cross-correlation exists
  - `coarse`: report only; do not claim sample-accurate sync

### Regression tests

Before considering implementation complete:

```bash
swift build -c release
scripts/.venv/bin/python3 -m py_compile scripts/*.py
bash -n meetgist-toggle.sh scripts/*.sh
```

Also run one existing successful meeting folder through:

```bash
scripts/transcribe_meeting.sh <existing-session-dir>
```

Expected:

- Existing folder transcription still works.
- New sync artifacts are additive.
- No existing output filenames are removed or renamed.

## Agent instructions

When giving this to a coding agent, ask it to implement only Phases 1 and 2 in
the first pass.

Do not let the agent start with AVAudioEngine or a single writer rewrite. The
first pass should be additive and low-risk:

1. Add `capture_timing.json`.
2. Add `sync_tracks.py`.
3. Hook sync map generation into `postprocess.py`.
4. Add pure tests for mapping and missing metadata.
5. Verify existing recording and postprocess behavior.

After Phases 1 and 2 are verified, decide whether Phase 3 can be implemented
without destabilizing transcription.

## Done criteria for first agent pass

- A new short recording produces:
  - `system.m4a`
  - `mic.m4a`
  - `capture_timing.json`
  - `sync_map.json`
  - `sync_report.md`
  - existing transcript/summary artifacts
- Existing recordings can still be transcribed.
- Sync script has tests for affine mapping and missing metadata.
- Verification commands pass:

```bash
swift build -c release
scripts/.venv/bin/python3 -m py_compile scripts/*.py
bash -n meetgist-toggle.sh scripts/*.sh
```

