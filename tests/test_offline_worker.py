import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

WORKER_PATH = Path(__file__).parents[1] / "Sources" / "MeetGistKit" / "Resources" / "offline_worker.py"
SPEC = importlib.util.spec_from_file_location("offline_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


class FakeAudio:
    def __init__(self, length):
        self.length = length

    def __len__(self):
        return self.length

    def __getitem__(self, value):
        if isinstance(value, slice):
            start = value.start or 0
            stop = self.length if value.stop is None else min(value.stop, self.length)
            return FakeAudio(max(0, stop - start))
        return 0.1

    def __array__(self, dtype=None, copy=None):
        import numpy

        return numpy.array([0.1], dtype=dtype)


class PatternAudio:
    def __init__(self, length, speech_until, offset=0):
        self.length = length
        self.speech_until = speech_until
        self.offset = offset

    def __len__(self):
        return self.length

    def __getitem__(self, value):
        if isinstance(value, slice):
            start = value.start or 0
            stop = self.length if value.stop is None else min(value.stop, self.length)
            return PatternAudio(max(0, stop - start), self.speech_until, self.offset + start)
        return 0.1 if self.offset + value < self.speech_until else 0.0


class FakeModel:
    def __init__(self, fail_call=None):
        self.calls = []
        self.fail_call = fail_call

    def transcribe(self, audio, **kwargs):
        self.calls.append((len(audio), kwargs))
        if self.fail_call == len(self.calls):
            raise RuntimeError("simulated crash")
        return {"segments": [{"start": 6.0, "end": 8.0, "text": f"chunk {len(self.calls)}"}]}


def initial_state(session_id="session", duration=601.0):
    return {
        "schema_version": 1,
        "job_id": "offline-test",
        "session_id": session_id,
        "status": "pending",
        "config_id": worker.CONFIG_ID,
        "config": {
            "engine": worker.ENGINE,
            "model": worker.MODEL,
            "language": "auto",
            "vocabulary": "MeetGist, Swift",
            "chunk_seconds": 300.0,
            "overlap_seconds": 5.0,
        },
        "tracks": {"system": {"duration_seconds": duration}},
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


class OfflineWorkerTests(unittest.TestCase):
    def test_fixed_chunks_and_overlap(self):
        chunks = worker.chunk_intervals(601.0, 300.0, 5.0)
        self.assertEqual(len(chunks), 3)
        self.assertEqual(chunks[0], {"index": 0, "core_start": 0.0, "core_end": 300.0, "audio_start": 0.0, "audio_end": 305.0})
        self.assertEqual(chunks[1]["audio_start"], 295.0)
        self.assertEqual(chunks[1]["audio_end"], 601.0)
        self.assertEqual(chunks[2]["audio_start"], 595.0)
        self.assertEqual(chunks[2]["audio_end"], 601.0)

    def test_midpoint_owns_overlap_segments(self):
        self.assertTrue(worker.midpoint_owned(294.0, 298.0, 0.0, 300.0))
        self.assertFalse(worker.midpoint_owned(299.0, 303.0, 0.0, 300.0))
        self.assertTrue(worker.midpoint_owned(299.0, 303.0, 300.0, 600.0))

    def test_crash_resume_reuses_committed_part_and_model_once_per_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"audio")
            worker.atomic_json(session / "transcription" / "state.json", initial_state())

            first_model = FakeModel(fail_call=2)
            with self.assertRaisesRegex(RuntimeError, "simulated crash"):
                worker.run_job(
                    session,
                    Path("model"),
                    transcriber_factory=lambda *_args, **_kwargs: first_model,
                    decode=lambda *_args: FakeAudio(601 * worker.SAMPLE_RATE),
                )
            self.assertEqual(len(first_model.calls), 2)
            self.assertTrue((parts / "system-0000.json").exists())
            self.assertFalse((parts / "system-0001.json").exists())

            second_model = FakeModel()
            result = worker.run_job(
                session,
                Path("model"),
                transcriber_factory=lambda *_args, **_kwargs: second_model,
                decode=lambda *_args: FakeAudio(601 * worker.SAMPLE_RATE),
            )
            self.assertEqual(result, 0)
            self.assertEqual(len(second_model.calls), 2)
            state = json.loads((session / "transcription" / "state.json").read_text())
            self.assertEqual(state["status"], "completed")
            self.assertEqual(state["progress"]["processed_seconds"], 601.0)
            self.assertIsNotNone(state["progress"]["rolling_rtf"])
            self.assertEqual(state["progress"]["eta_seconds"], 0)

    def test_corrupt_part_and_abandoned_temporary_are_reprocessed(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"audio")
            worker.atomic_json(session / "transcription" / "state.json", initial_state(duration=10.0))
            (parts / "system-0000.json").write_text("not json")
            (parts / "system-0001.json.tmp").write_text("partial")
            model = FakeModel()
            worker.run_job(
                session,
                Path("model"),
                transcriber_factory=lambda *_args, **_kwargs: model,
                decode=lambda *_args: FakeAudio(10 * worker.SAMPLE_RATE),
            )
            self.assertEqual(len(model.calls), 1)
            self.assertFalse((parts / "system-0001.json.tmp").exists())
            self.assertTrue(json.loads((parts / "system-0000.json").read_text())["segments"])

    def test_parseable_part_with_invalid_segment_is_reprocessed(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"audio")
            state = initial_state(duration=10.0)
            worker.atomic_json(session / "transcription" / "state.json", state)
            worker.atomic_json(parts / "system-0000.json", {
                "schema_version": 1,
                "job_id": state["job_id"],
                "session_id": state["session_id"],
                "config_id": worker.CONFIG_ID,
                "track": "system",
                "chunk_index": 0,
                "core_start_seconds": 0.0,
                "core_end_seconds": 10.0,
                "processing_seconds": 1.0,
                "segments": [{"text": "missing timestamps"}],
            })
            model = FakeModel()

            result = worker.run_job(
                session,
                Path("model"),
                transcriber_factory=lambda *_args, **_kwargs: model,
                decode=lambda *_args: FakeAudio(10 * worker.SAMPLE_RATE),
            )

            self.assertEqual(result, 0)
            self.assertEqual(len(model.calls), 1)
            repaired = json.loads((parts / "system-0000.json").read_text())
            self.assertIn("start_seconds", repaired["segments"][0])

    def test_offset_only_merge_sorts_tracks(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            state = initial_state(duration=10.0)
            state["tracks"]["mic"] = {"duration_seconds": 10.0}
            for track, start, text in (("system", 5.0, "system"), ("mic", 2.0, "mic")):
                part = {
                    "schema_version": 1,
                    "job_id": state["job_id"],
                    "session_id": state["session_id"],
                    "config_id": worker.CONFIG_ID,
                    "track": track,
                    "chunk_index": 0,
                    "core_start_seconds": 0.0,
                    "core_end_seconds": 10.0,
                    "processing_seconds": 1.0,
                    "segments": [{"start_seconds": start, "end_seconds": start + 1, "text": text}],
                }
                worker.atomic_json(parts / f"{track}-0000.json", part)
            (session / "sync_map.json").write_text(json.dumps({
                "system": {"offset_seconds": 0.0, "scale": 1.0},
                "mic": {"offset_seconds": 4.0, "scale": 123.0},
            }))
            worker.merge_transcript(session, state, parts, {"system": 10.0, "mic": 10.0})
            lines = (session / "transcript.md").read_text().splitlines()
            self.assertEqual(lines, ["[00:05] Speaker: system", "[00:06] Me: mic"])

    def test_missing_sync_map_is_generated_from_capture_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            state = initial_state(duration=10.0)
            state["tracks"]["mic"] = {"duration_seconds": 10.0}
            (session / "capture_timing.json").write_text(json.dumps({
                "system": {"first_buffer_host_ns": 1_000_000_000},
                "mic": {"record_started_host_ns": 3_000_000_000},
            }))
            for track, start in (("system", 5.0), ("mic", 2.0)):
                worker.atomic_json(parts / f"{track}-0000.json", {
                    "schema_version": 1,
                    "job_id": state["job_id"],
                    "session_id": state["session_id"],
                    "config_id": worker.CONFIG_ID,
                    "track": track,
                    "chunk_index": 0,
                    "core_start_seconds": 0.0,
                    "core_end_seconds": 10.0,
                    "processing_seconds": 1.0,
                    "segments": [{"start_seconds": start, "end_seconds": start + 1, "text": track}],
                })

            worker.merge_transcript(session, state, parts, {"system": 10.0, "mic": 10.0})

            sync_map = json.loads((session / "sync_map.json").read_text())
            self.assertEqual(sync_map["mic"]["offset_seconds"], 2.0)
            self.assertEqual(sync_map["confidence"], "coarse")
            self.assertNotIn("No usable sync timing; track offsets assumed 0.", state["warnings"])
            self.assertEqual((session / "transcript.md").read_text().splitlines(), [
                "[00:04] Me: mic", "[00:05] Speaker: system",
            ])

    def test_tracks_and_chunks_are_strictly_sequential_and_model_loads_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"system")
            (session / "mic.m4a").write_bytes(b"mic")
            state = initial_state(duration=301.0)
            state["tracks"]["mic"] = {"duration_seconds": 301.0}
            worker.atomic_json(session / "transcription" / "state.json", state)
            events = []
            model = FakeModel()

            def factory(*_args, **_kwargs):
                events.append("model")
                return model

            def decode(path, _rate):
                events.append(Path(path).name)
                return FakeAudio(301 * worker.SAMPLE_RATE)

            worker.run_job(session, Path("model"), transcriber_factory=factory, decode=decode)
            self.assertEqual(events, ["system.m4a", "model", "mic.m4a"])
            self.assertEqual(len(model.calls), 4)
            for _length, options in model.calls:
                self.assertEqual(set(options), {"language", "initial_prompt"})

    def test_bad_track_warns_but_other_track_completes_and_both_bad_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"system")
            (session / "mic.m4a").write_bytes(b"mic")
            state = initial_state(duration=10.0)
            state["tracks"]["mic"] = {"duration_seconds": 10.0}
            worker.atomic_json(session / "transcription" / "state.json", state)

            def one_bad(path, _rate):
                if path.endswith("mic.m4a"):
                    raise ValueError("corrupt")
                return FakeAudio(10 * worker.SAMPLE_RATE)

            result = worker.run_job(session, Path("model"),
                                    transcriber_factory=lambda *_args, **_kwargs: FakeModel(), decode=one_bad)
            self.assertEqual(result, 0)
            done = json.loads((session / "transcription" / "state.json").read_text())
            self.assertEqual(done["status"], "completed")
            self.assertTrue(any("mic.m4a could not be decoded" in item for item in done["warnings"]))

        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"system")
            (session / "mic.m4a").write_bytes(b"mic")
            state = initial_state(duration=10.0)
            state["tracks"]["mic"] = {"duration_seconds": 10.0}
            worker.atomic_json(session / "transcription" / "state.json", state)
            result = worker.run_job(
                session, Path("model"), transcriber_factory=lambda *_args, **_kwargs: FakeModel(),
                decode=lambda *_args: (_ for _ in ()).throw(ValueError("corrupt")),
            )
            self.assertEqual(result, 2)
            failed = json.loads((session / "transcription" / "state.json").read_text())
            self.assertEqual(failed["status"], "failed")

    def test_missing_and_empty_tracks_fail_without_loading_mlx(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "mic.m4a").write_bytes(b"")
            state = initial_state(duration=10.0)
            state["tracks"]["mic"] = {"duration_seconds": 10.0}
            worker.atomic_json(session / "transcription" / "state.json", state)
            loaded = []

            result = worker.run_job(
                session, Path("model"),
                transcriber_factory=lambda *_args: loaded.append(True),
                decode=lambda *_args: self.fail("empty tracks must not be decoded"),
            )

            self.assertEqual(result, 2)
            self.assertEqual(loaded, [])
            failed = json.loads((session / "transcription" / "state.json").read_text())
            self.assertTrue(any("system.m4a is missing or empty" in item for item in failed["warnings"]))
            self.assertTrue(any("mic.m4a is missing or empty" in item for item in failed["warnings"]))

    def test_silence_guard_commits_empty_chunk_without_calling_mlx(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            parts = session / "transcription" / "parts"
            parts.mkdir(parents=True)
            (session / "system.m4a").write_bytes(b"audio")
            state = initial_state(duration=2.0)
            state["config"]["chunk_seconds"] = 1.0
            state["config"]["overlap_seconds"] = 0.0
            worker.atomic_json(session / "transcription" / "state.json", state)
            model = FakeModel()
            audio = PatternAudio(2 * worker.SAMPLE_RATE, speech_until=worker.SAMPLE_RATE)
            result = worker.run_job(
                session, Path("model"), transcriber_factory=lambda *_args: model,
                decode=lambda *_args: audio,
            )
            self.assertEqual(result, 0)
            self.assertEqual(len(model.calls), 1)
            silent_part = json.loads((parts / "system-0001.json").read_text())
            self.assertEqual(silent_part["segments"], [])

    def test_mic_track_uses_canonical_audio(self):
        """A leftover derived file must never replace canonical mic audio."""
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            (session / "transcription" / "parts").mkdir(parents=True)
            (session / "mic.m4a").write_bytes(b"audio")
            (session / "transcription" / "mic.aec.wav").write_bytes(b"stale derived audio")
            state = initial_state(duration=6.0)
            state["tracks"] = {"mic": {"duration_seconds": 6.0}}
            worker.atomic_json(session / "transcription" / "state.json", state)
            decoded_paths = []

            def decode(path, _sr):
                decoded_paths.append(path)
                return FakeAudio(6 * worker.SAMPLE_RATE)

            result = worker.run_job(
                session, Path("model"),
                transcriber_factory=lambda *_args: FakeModel(),
                decode=decode,
            )

            self.assertEqual(result, 0)
            self.assertEqual(decoded_paths, [str(session / "mic.m4a")])


if __name__ == "__main__":
    unittest.main()
