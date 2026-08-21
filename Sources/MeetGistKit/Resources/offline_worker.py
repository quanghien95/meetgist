#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Single-job MLX Whisper worker for MeetGist offline transcription v1."""

from __future__ import annotations

import argparse
import json
import math
import os
import signal
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterable

SCHEMA_VERSION = 1
CONFIG_ID = "mlx-whisper-large-v3-v1"
ENGINE = "mlx-whisper"
MODEL = "mlx-community/whisper-large-v3-mlx"
SAMPLE_RATE = 16_000
TRACKS = (
    ("system", "system.m4a", "Speaker"),
    ("mic", "mic.m4a", "Me"),
)

_stop_requested = False


def _request_stop(_signum: int, _frame: Any) -> None:
    global _stop_requested
    _stop_requested = True


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    payload = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    with temporary.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(value)
        if not value.endswith("\n"):
            handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def chunk_intervals(duration: float, chunk_seconds: float, overlap_seconds: float) -> list[dict[str, float]]:
    chunks: list[dict[str, float]] = []
    index = 0
    core_start = 0.0
    while core_start < duration:
        core_end = min(duration, core_start + chunk_seconds)
        chunks.append(
            {
                "index": index,
                "core_start": core_start,
                "core_end": core_end,
                "audio_start": max(0.0, core_start - overlap_seconds),
                "audio_end": min(duration, core_end + overlap_seconds),
            }
        )
        index += 1
        core_start += chunk_seconds
    return chunks


def midpoint_owned(start: float, end: float, core_start: float, core_end: float) -> bool:
    midpoint = (start + end) / 2.0
    return core_start <= midpoint < core_end


def valid_part(
    part: Any,
    state: dict[str, Any],
    track: str,
    chunk: dict[str, float],
) -> bool:
    if not isinstance(part, dict):
        return False
    expected = {
        "schema_version": SCHEMA_VERSION,
        "job_id": state.get("job_id"),
        "session_id": state.get("session_id"),
        "config_id": CONFIG_ID,
        "track": track,
        "chunk_index": chunk["index"],
    }
    if any(part.get(key) != value for key, value in expected.items()):
        return False
    try:
        return math.isclose(float(part["core_start_seconds"]), chunk["core_start"], abs_tol=0.001) and math.isclose(
            float(part["core_end_seconds"]), chunk["core_end"], abs_tol=0.001
        ) and isinstance(part.get("segments"), list)
    except (KeyError, TypeError, ValueError):
        return False


def load_valid_part(path: Path, state: dict[str, Any], track: str, chunk: dict[str, float]) -> dict[str, Any] | None:
    try:
        part = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return part if valid_part(part, state, track, chunk) else None


def cleanup_temporaries(transcription_dir: Path) -> None:
    if not transcription_dir.exists():
        return
    for path in transcription_dir.rglob("*.tmp"):
        try:
            path.unlink()
        except OSError:
            pass


def has_meaningful_speech(audio: Any, sampling_rate: int = SAMPLE_RATE) -> bool:
    """Small energy gate that rejects silence without becoming a VAD subsystem."""
    if len(audio) == 0:
        return False
    try:
        import numpy as np

        samples = np.asarray(audio, dtype=np.float32).reshape(-1)
        frame_samples = max(1, round(0.03 * sampling_rate))
        frame_count = len(samples) // frame_samples
        if frame_count == 0:
            return float(np.max(np.abs(samples))) >= 10 ** (-48 / 20)
        frames = samples[: frame_count * frame_samples].reshape(frame_count, frame_samples)
        rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
        active_seconds = float(np.count_nonzero(rms >= 10 ** (-48 / 20))) * 0.03
        duration = len(samples) / sampling_rate
        required_seconds = min(0.24, max(0.03, duration * 0.5))
        return active_seconds >= required_seconds
    except ImportError:
        # The production runtime always has NumPy via MLX Whisper. This small
        # fallback keeps pure fake-model tests dependency-free without walking a
        # multi-hour buffer one Python object at a time.
        stride = max(1, len(audio) // 4096)
        return max(abs(float(audio[index])) for index in range(0, len(audio), stride)) >= 10 ** (-48 / 20)


def is_silent(audio: Any) -> bool:
    return not has_meaningful_speech(audio)


def _segments_from_result(
    result: Iterable[Any], audio_start: float, core_start: float, core_end: float
) -> list[dict[str, Any]]:
    accepted: list[dict[str, Any]] = []
    for segment in result:
        if isinstance(segment, dict):
            start, end, raw_text = segment.get("start", 0), segment.get("end", 0), segment.get("text", "")
        else:
            start, end, raw_text = segment.start, segment.end, segment.text
        local_start = audio_start + float(start)
        local_end = audio_start + float(end)
        text = str(raw_text).strip()
        if text and midpoint_owned(local_start, local_end, core_start, core_end):
            accepted.append(
                {
                    "start_seconds": round(local_start, 3),
                    "end_seconds": round(local_end, 3),
                    "text": text,
                }
            )
    return accepted


def _committed_parts(
    parts_dir: Path, state: dict[str, Any], durations: dict[str, float]
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, float], list[float]]:
    config = state["config"]
    found: dict[str, list[dict[str, Any]]] = {"system": [], "mic": []}
    track_seconds = {"system": 0.0, "mic": 0.0}
    rtfs: list[float] = []
    for track, _filename, _speaker in TRACKS:
        for chunk in chunk_intervals(durations.get(track, 0.0), config["chunk_seconds"], config["overlap_seconds"]):
            path = parts_dir / f"{track}-{int(chunk['index']):04d}.json"
            part = load_valid_part(path, state, track, chunk)
            if part is None:
                continue
            found[track].append(part)
            core_seconds = chunk["core_end"] - chunk["core_start"]
            track_seconds[track] += core_seconds
            if core_seconds > 0:
                rtfs.append(float(part.get("processing_seconds", 0.0)) / core_seconds)
    return found, track_seconds, rtfs


def update_progress(state: dict[str, Any], parts_dir: Path, durations: dict[str, float]) -> None:
    _parts, track_seconds, rtfs = _committed_parts(parts_dir, state, durations)
    processed = sum(track_seconds.values())
    total = sum(durations.values())
    recent = rtfs[-5:]
    rolling_rtf = sum(recent) / len(recent) if recent else None
    remaining = max(0.0, total - processed)
    previous = state.get("progress") or {}
    state["progress"] = {
        "processed_seconds": round(processed, 3),
        "total_seconds": round(total, 3),
        "track_processed_seconds": {key: round(value, 3) for key, value in track_seconds.items()},
        "rolling_rtf": round(rolling_rtf, 4) if rolling_rtf is not None else None,
        "eta_seconds": int(round(remaining * rolling_rtf)) if rolling_rtf is not None else None,
        "current_track": previous.get("current_track"),
        "current_chunk": previous.get("current_chunk"),
    }


def _stamp(seconds: float) -> str:
    value = max(0, int(seconds))
    hours, remainder = divmod(value, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}" if hours else f"{minutes:02d}:{secs:02d}"


def track_offsets(session_dir: Path, state: dict[str, Any]) -> dict[str, float]:
    offsets = {"system": 0.0, "mic": 0.0}
    sync_path = session_dir / "sync_map.json"
    if sync_path.exists():
        try:
            sync_map = json.loads(sync_path.read_text(encoding="utf-8"))
            for track in offsets:
                offsets[track] = float((sync_map.get(track) or {}).get("offset_seconds", 0.0))
            return offsets
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            state.setdefault("warnings", []).append("Unreadable sync_map.json; track offsets assumed 0.")
            return offsets

    # Native recording already writes these shared host-clock anchors. Materialize
    # the existing coarse v1 map here so local transcription does not need the
    # legacy postprocess.py entry point.
    timing_path = session_dir / "capture_timing.json"
    try:
        timing = json.loads(timing_path.read_text(encoding="utf-8"))
        system_anchor = int((timing.get("system") or {}).get("first_buffer_host_ns") or 0)
        mic_anchor = int((timing.get("mic") or {}).get("record_started_host_ns") or 0)
        if system_anchor and mic_anchor:
            offsets["mic"] = (mic_anchor - system_anchor) / 1_000_000_000
            generated = {
                "schema_version": 1,
                "master": "system",
                "system": {"file": "system.m4a", "offset_seconds": 0.0, "scale": 1.0},
                "mic": {
                    "file": "mic.m4a",
                    "offset_seconds": round(offsets["mic"], 6),
                    "scale": 1.0,
                },
                "confidence": "coarse",
                "warnings": [],
            }
            atomic_json(sync_path, generated)
            return offsets
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass

    state.setdefault("warnings", []).append("No usable sync timing; track offsets assumed 0.")
    return offsets


def merge_transcript(session_dir: Path, state: dict[str, Any], parts_dir: Path, durations: dict[str, float]) -> None:
    offsets = track_offsets(session_dir, state)

    parts, _seconds, _rtfs = _committed_parts(parts_dir, state, durations)
    speakers = {track: speaker for track, _filename, speaker in TRACKS}
    lines: list[tuple[float, int, str]] = []
    order = 0
    for track, _filename, _speaker in TRACKS:
        for part in parts[track]:
            for segment in part["segments"]:
                meeting_time = float(segment["start_seconds"]) + offsets[track]
                lines.append((meeting_time, order, f"[{_stamp(meeting_time)}] {speakers[track]}: {segment['text']}"))
                order += 1
    lines.sort(key=lambda item: (item[0], item[1]))
    atomic_text(session_dir / "transcript.md", "\n".join(line for _time, _order, line in lines))


class _MLXTranscriber:
    def __init__(self, model_dir: str):
        import mlx_whisper

        self._model_dir = model_dir
        self._transcribe = mlx_whisper.transcribe

    def transcribe(self, audio: Any, *, language: str | None, initial_prompt: str | None) -> dict[str, Any]:
        # mlx-whisper's pinned public transcribe API keeps a process-local model
        # holder, so repeated calls with this same local path reuse one model.
        return self._transcribe(
            audio,
            path_or_hf_repo=self._model_dir,
            verbose=None,
            language=language,
            initial_prompt=initial_prompt,
            word_timestamps=False,
        )


def _default_transcriber_factory(model_dir: str) -> Any:
    return _MLXTranscriber(model_dir)


def _default_decode(path: str, sampling_rate: int) -> Any:
    import av
    import numpy as np

    samples: list[Any] = []
    resampler = av.AudioResampler(format="s16", layout="mono", rate=sampling_rate)
    with av.open(path) as container:
        for frame in container.decode(audio=0):
            for converted in resampler.resample(frame):
                samples.append(converted.to_ndarray().reshape(-1))
        for converted in resampler.resample(None):
            samples.append(converted.to_ndarray().reshape(-1))
    if not samples:
        return np.empty(0, dtype=np.float32)
    return np.concatenate(samples).astype(np.float32) / 32768.0


def run_job(
    session_dir: Path,
    model_dir: Path,
    transcriber_factory: Callable[[str], Any] = _default_transcriber_factory,
    decode: Callable[[str, int], Any] = _default_decode,
) -> int:
    global _stop_requested
    _stop_requested = False
    transcription_dir = session_dir / "transcription"
    parts_dir = transcription_dir / "parts"
    state_path = transcription_dir / "state.json"
    cleanup_temporaries(transcription_dir)
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state.get("schema_version") != SCHEMA_VERSION or state.get("config_id") != CONFIG_ID:
        raise ValueError("unsupported offline transcription state/config")
    config = state.get("config") or {}
    if config.get("engine") != ENGINE or config.get("model") != MODEL:
        raise ValueError("offline transcription engine/model does not match this worker")

    state["status"] = "transcribing"
    state["last_error"] = None
    state.setdefault("warnings", [])
    atomic_json(state_path, state)

    durations = {key: float(value["duration_seconds"]) for key, value in state.get("tracks", {}).items()}
    usable_tracks = 0
    transcriber = None

    for track, filename, _speaker in TRACKS:
        if _stop_requested:
            return 75
        source = session_dir / filename
        if not source.exists() or source.stat().st_size == 0:
            state["warnings"].append(f"{filename} is missing or empty; skipped.")
            durations.pop(track, None)
            state.get("tracks", {}).pop(track, None)
            atomic_json(state_path, state)
            continue
        try:
            audio = decode(str(source), SAMPLE_RATE)
        except Exception as error:
            state["warnings"].append(f"{filename} could not be decoded; skipped: {error}")
            durations.pop(track, None)
            state.get("tracks", {}).pop(track, None)
            atomic_json(state_path, state)
            continue
        if not has_meaningful_speech(audio):
            state["warnings"].append(f"{filename} is silent; skipped.")
            durations.pop(track, None)
            state.get("tracks", {}).pop(track, None)
            atomic_json(state_path, state)
            del audio
            continue

        usable_tracks += 1
        if transcriber is None:
            # One adapter and one mlx-whisper process-local model serve all chunks.
            transcriber = transcriber_factory(str(model_dir))
        duration = len(audio) / SAMPLE_RATE
        durations[track] = duration
        state.setdefault("tracks", {})[track] = {"duration_seconds": round(duration, 3)}
        update_progress(state, parts_dir, durations)
        atomic_json(state_path, state)

        config = state["config"]
        for chunk in chunk_intervals(duration, config["chunk_seconds"], config["overlap_seconds"]):
            if _stop_requested:
                del audio
                return 75
            part_path = parts_dir / f"{track}-{int(chunk['index']):04d}.json"
            if load_valid_part(part_path, state, track, chunk) is not None:
                continue

            audio_start = chunk["audio_start"]
            first_sample = int(round(audio_start * SAMPLE_RATE))
            last_sample = int(round(chunk["audio_end"] * SAMPLE_RATE))
            started = time.monotonic()
            chunk_audio = audio[first_sample:last_sample]
            state["progress"]["current_track"] = track
            state["progress"]["current_chunk"] = int(chunk["index"])
            atomic_json(state_path, state)
            language = config.get("language")
            language = None if not language or language == "auto" else language
            vocabulary = str(config.get("vocabulary") or "").strip() or None
            if has_meaningful_speech(chunk_audio):
                result = transcriber.transcribe(chunk_audio, language=language, initial_prompt=vocabulary)
                accepted = _segments_from_result(
                    result.get("segments") or [], audio_start, chunk["core_start"], chunk["core_end"]
                )
            else:
                accepted = []
            if _stop_requested:
                del audio
                return 75
            part = {
                "schema_version": SCHEMA_VERSION,
                "job_id": state["job_id"],
                "session_id": state["session_id"],
                "config_id": CONFIG_ID,
                "track": track,
                "chunk_index": int(chunk["index"]),
                "core_start_seconds": round(chunk["core_start"], 3),
                "core_end_seconds": round(chunk["core_end"], 3),
                "processing_seconds": round(time.monotonic() - started, 3),
                "segments": accepted,
            }
            atomic_json(part_path, part)
            update_progress(state, parts_dir, durations)
            atomic_json(state_path, state)
            print(json.dumps({"event": "committed", "track": track, "chunk_index": int(chunk["index"])}), flush=True)
        del audio
        state["progress"]["current_track"] = None
        state["progress"]["current_chunk"] = None
        atomic_json(state_path, state)

    if usable_tracks == 0:
        state["status"] = "failed"
        state["last_error"] = "Neither system.m4a nor mic.m4a contains usable audio."
        update_progress(state, parts_dir, durations)
        atomic_json(state_path, state)
        return 2

    merge_transcript(session_dir, state, parts_dir, durations)
    update_progress(state, parts_dir, durations)
    state["progress"]["current_track"] = None
    state["progress"]["current_chunk"] = None
    state["status"] = "completed"
    state["last_error"] = None
    atomic_json(state_path, state)
    print(json.dumps({"event": "completed"}), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-dir", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)
    try:
        return run_job(args.session_dir, args.model_dir)
    except Exception as error:
        state_path = args.session_dir / "transcription" / "state.json"
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["status"] = "failed"
            state["last_error"] = str(error)
            atomic_json(state_path, state)
        except Exception:
            pass
        print(f"offline worker failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
