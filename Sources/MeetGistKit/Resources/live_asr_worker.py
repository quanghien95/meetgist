#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Persistent Live ASR worker for MeetGist's Live Meeting Copilot (plan §5.3).

Unlike `offline_worker_qwen.py` (one job, one process, model reloaded per
job), this worker loads a Qwen3-ASR model exactly once and then serves many
short transcription requests over a JSON-lines protocol on stdin/stdout for
as long as the recording with Live Assist enabled runs. It is a child
process of the app, never a daemon: `QwenLiveTranscriber` (Swift) starts one
per recording and stops it when Live Assist stops or recording ends.

Wire protocol, one JSON object per line:
  worker -> {"type": "ready", "load_ms": <float>, "peak_memory_mb": <float>}
  app    -> {"type": "transcribe", "id": <int>, "pcm_path": "<path>", "sample_rate": 16000}
  worker -> {"type": "result", "id": <int>, "text": "<str>", "asr_ms": <float>,
             "audio_seconds": <float>, "peak_memory_mb": <float>}
        or {"type": "error", "id": <int>, "message": "<str>"}
  app    -> {"type": "shutdown"}

`pcm_path` is a raw little-endian Float32 mono file at `sample_rate` (no
header) written by the Swift side into a private temp directory; the app
deletes it after reading the reply. SIGTERM terminates the process with its
default disposition (no custom handler) — deliberately simple, since a
worker that dies mid-request is already treated by the Swift side as "the
worker crashed" and reported as `QwenLiveTranscriberError.unavailable`.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Callable, TextIO

SAMPLE_RATE = 16_000
MAX_GENERATION_TOKENS = 512


class _Qwen3ASRTranscriber:
    """Mirrors `offline_worker_qwen.py`'s `_Qwen3ASRTranscriber`: same
    `mlx_audio.stt.utils.load_model` + `model.generate(...)` call shape, so
    both workers stay consistent if the upstream API changes."""

    def __init__(self, model_dir: str):
        from mlx_audio.stt.utils import load_model

        self._model = load_model(model_dir)

    def transcribe(self, audio: Any, *, language: str | None, hotwords: list[str] | None) -> str:
        result = self._model.generate(
            audio,
            language=language,
            hotwords=hotwords if hotwords else None,
            verbose=False,
            max_tokens=MAX_GENERATION_TOKENS,
        )
        if getattr(result, "generation_tokens", 0) >= MAX_GENERATION_TOKENS:
            raise RuntimeError("Live ASR exceeded its generation budget; result discarded")
        return (result.text or "").strip()


def _default_transcriber_factory(model_dir: str) -> Any:
    return _Qwen3ASRTranscriber(model_dir)


def _default_read_pcm(path: str) -> Any:
    import numpy as np

    return np.fromfile(path, dtype="<f4")


def peak_memory_mb() -> float:
    try:
        import resource

        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    except (ImportError, OSError):
        return 0.0
    # macOS reports ru_maxrss in bytes; Linux reports it in KiB.
    return (peak / (1024 * 1024)) if sys.platform == "darwin" else (peak / 1024)


def write_json(stdout: TextIO, payload: dict[str, Any]) -> None:
    stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    stdout.flush()


def handle_transcribe(
    stdout: TextIO,
    transcriber: Any,
    message: dict[str, Any],
    *,
    language: str | None,
    hotwords: list[str] | None,
    read_pcm: Callable[[str], Any],
    clock: Callable[[], float],
) -> None:
    request_id = message.get("id")
    try:
        pcm_path = message["pcm_path"]
        sample_rate = message.get("sample_rate", SAMPLE_RATE)
        audio = read_pcm(pcm_path)
        started = clock()
        text = transcriber.transcribe(audio, language=language, hotwords=hotwords)
        asr_ms = (clock() - started) * 1000
        audio_seconds = (len(audio) / float(sample_rate)) if sample_rate else 0.0
        write_json(stdout, {
            "type": "result",
            "id": request_id,
            "text": text,
            "asr_ms": round(asr_ms, 1),
            "audio_seconds": round(audio_seconds, 3),
            "peak_memory_mb": round(peak_memory_mb(), 1),
        })
    except Exception as error:  # noqa: BLE001 - reported back over the protocol, not raised
        write_json(stdout, {"type": "error", "id": request_id, "message": str(error)})


def run_worker(
    stdin: TextIO,
    stdout: TextIO,
    model_dir: str,
    language: str | None,
    hotwords: list[str] | None,
    transcriber_factory: Callable[[str], Any] = _default_transcriber_factory,
    read_pcm: Callable[[str], Any] = _default_read_pcm,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    load_start = clock()
    transcriber = transcriber_factory(model_dir)
    load_ms = (clock() - load_start) * 1000
    write_json(stdout, {"type": "ready", "load_ms": round(load_ms, 1), "peak_memory_mb": round(peak_memory_mb(), 1)})

    for raw_line in stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(message, dict):
            continue
        message_type = message.get("type")
        if message_type == "shutdown":
            break
        if message_type == "transcribe":
            request_language = message.get("language", language)
            if not request_language or request_language == "auto":
                request_language = None
            handle_transcribe(stdout, transcriber, message, language=request_language, hotwords=hotwords,
                              read_pcm=read_pcm, clock=clock)
        # Unknown message types are ignored rather than treated as fatal, so
        # a future protocol addition doesn't require a lockstep worker bump.
    return 0


def _hotwords_from_file(path: str | None) -> list[str] | None:
    if not path:
        return None
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    words = [w.strip() for w in text.replace("\n", ",").split(",") if w.strip()]
    return words or None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--language", default=None)
    parser.add_argument("--hotwords-file", default=None)
    args = parser.parse_args()
    language = None if not args.language or args.language == "auto" else args.language
    hotwords = _hotwords_from_file(args.hotwords_file)
    return run_worker(sys.stdin, sys.stdout, args.model_dir, language, hotwords)


if __name__ == "__main__":
    raise SystemExit(main())
