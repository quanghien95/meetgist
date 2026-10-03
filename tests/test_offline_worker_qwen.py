#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Qwen worker coverage for canonical mic audio and runaway output retries.

`test_offline_worker.py` covers the shared chunk/state/part contract in depth
for the Whisper worker.
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

# offline_worker_qwen.py's own `has_meaningful_speech` imports numpy
# unconditionally (unlike offline_worker.py's, which has a pure-Python
# fallback specifically so its fake-model tests stay dependency-free) — so
# these tests need numpy on `python3`'s path. `make test`'s plain `python3`
# doesn't have it on every machine; skip cleanly rather than fail the whole
# suite when it's missing (run with a Python that has numpy, e.g. the app's
# bundled Qwen3ASR runtime, to actually exercise this file).
if importlib.util.find_spec("numpy") is None:
    raise unittest.SkipTest("offline_worker_qwen tests need numpy on this Python")

WORKER_PATH = Path(__file__).parents[1] / "Sources" / "MeetGistKit" / "Resources" / "offline_worker_qwen.py"
SPEC = importlib.util.spec_from_file_location("offline_worker_qwen", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


def loud_audio(seconds):
    import numpy as np

    return np.full(int(seconds * worker.SAMPLE_RATE), 0.2, dtype=np.float32)


class FakeQwenModel:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio, **kwargs):
        self.calls.append((len(audio), kwargs))
        return f"chunk {len(self.calls)}"


def initial_state(duration=6.0):
    return {
        "schema_version": 1,
        "job_id": "offline-test",
        "session_id": "session",
        "status": "pending",
        "config_id": "qwen3-asr-test-v1",
        "config": {
            "engine": worker.ENGINE,
            "model": worker.MODEL,
            "language": "auto",
            "vocabulary": "",
            "chunk_seconds": 300.0,
            "overlap_seconds": 5.0,
        },
        "tracks": {},
        "progress": {
            "processed_seconds": 0.0,
            "total_seconds": duration,
            "track_processed_seconds": {"system": 0.0, "mic": 0.0},
            "rolling_rtf": None,
            "eta_seconds": None,
        },
        "last_error": None,
        "warnings": [],
    }


class OfflineWorkerQwenAudioTests(unittest.TestCase):
    def test_mic_track_uses_canonical_audio(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "mic.m4a").write_bytes(b"audio")
            (session / "transcription" / "mic.aec.wav").write_bytes(b"stale derived audio")
            state = initial_state()
            state["tracks"] = {"mic": {"duration_seconds": 6.0}}
            worker.atomic_json(session / "transcription" / "state.json", state)
            decoded_paths = []

            def decode(path, _sr):
                decoded_paths.append(path)
                return loud_audio(6.0)

            result = worker.run_job(
                session, Path("model"),
                transcriber_factory=lambda *_args: FakeQwenModel(),
                decode=decode,
            )

            self.assertEqual(result, 0)
            self.assertEqual(decoded_paths, [str(session / "mic.m4a")])


class QwenOutputGuardTests(unittest.TestCase):
    def test_repeated_output_retries_smaller_audio_with_accurate_times(self):
        class LoopOnLongAudio:
            def __init__(self):
                self.calls = []

            def transcribe(self, audio, **_kwargs):
                self.calls.append(len(audio))
                if len(audio) > 15 * worker.SAMPLE_RATE:
                    return "because of the reason, um, " * 10
                return "short segment"

        model = LoopOnLongAudio()
        segments = worker.transcribe_segments(model, loud_audio(30), 600, None, None)
        self.assertEqual(model.calls, [30 * worker.SAMPLE_RATE, 15 * worker.SAMPLE_RATE,
                                       15 * worker.SAMPLE_RATE])
        self.assertEqual([(s["start_seconds"], s["end_seconds"]) for s in segments],
                         [(600, 615), (615, 630)])
        self.assertEqual([s["text"] for s in segments], ["short segment", "short segment"])

    def test_token_cap_retries_and_persistent_loop_fails_closed(self):
        class CappedModel:
            def transcribe(self, _audio, **_kwargs):
                raise worker.QwenOutputTooLong

        with self.assertRaisesRegex(RuntimeError, "repeated or excessive text"):
            worker.transcribe_segments(CappedModel(), loud_audio(30), 0, None, None)

    def test_short_normal_output_stays_one_segment(self):
        model = FakeQwenModel()
        segments = worker.transcribe_segments(model, loud_audio(30), 10, None, None)
        self.assertEqual(len(model.calls), 1)
        self.assertEqual([(s["start_seconds"], s["end_seconds"]) for s in segments], [(10, 40)])


if __name__ == "__main__":
    unittest.main()
