import importlib.util
import io
import json
import sys
import tempfile
import unittest
from types import SimpleNamespace
from pathlib import Path

sys.dont_write_bytecode = True

WORKER_PATH = Path(__file__).parents[1] / "Sources" / "MeetGistKit" / "Resources" / "live_asr_worker.py"
SPEC = importlib.util.spec_from_file_location("live_asr_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


class FakeTranscriber:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio, *, language, hotwords):
        self.calls.append({"audio_len": len(audio), "language": language, "hotwords": hotwords})
        return f"transcribed {len(audio)} samples"


def read_lines(stdout: io.StringIO) -> list[dict]:
    stdout.seek(0)
    return [json.loads(line) for line in stdout.read().splitlines() if line.strip()]


class LiveASRWorkerTests(unittest.TestCase):
    def test_model_generation_is_bounded_and_exhaustion_is_not_published(self):
        transcriber = object.__new__(worker._Qwen3ASRTranscriber)
        class Model:
            def __init__(self):
                self.tokens = 10
                self.kwargs = None
            def generate(self, audio, **kwargs):
                self.kwargs = kwargs
                return SimpleNamespace(text="Valid local speech", generation_tokens=self.tokens)
        model = Model()
        transcriber._model = model
        self.assertEqual(transcriber.transcribe([0.1], language=None, hotwords=None), "Valid local speech")
        self.assertEqual(model.kwargs["max_tokens"], 512)
        model.tokens = 512
        with self.assertRaisesRegex(RuntimeError, "generation budget"):
            transcriber.transcribe([0.1], language=None, hotwords=None)

    def test_language_can_change_per_request_without_reloading_model(self):
        requests = [
            {"type": "transcribe", "id": 1, "pcm_path": "x"},
            {"type": "transcribe", "id": 2, "pcm_path": "x", "language": "auto"},
            {"type": "transcribe", "id": 3, "pcm_path": "x", "language": "vi"},
        ]
        transcriber = FakeTranscriber()
        loads = []
        def factory(model_dir):
            loads.append(model_dir)
            return transcriber
        worker.run_worker(io.StringIO("\n".join(json.dumps(r) for r in requests)), io.StringIO(),
                          "local-model", "en", None, transcriber_factory=factory,
                          read_pcm=lambda _: [0.1] * 16000)
        self.assertEqual(loads, ["local-model"])
        self.assertEqual([c["language"] for c in transcriber.calls], ["en", None, "vi"])

    def test_ready_message_reports_load_time_and_memory(self):
        stdin = io.StringIO("")   # EOF immediately after load — no requests
        stdout = io.StringIO()
        transcriber = FakeTranscriber()

        result = worker.run_worker(
            stdin, stdout, "model-dir", None, None,
            transcriber_factory=lambda _dir: transcriber,
            read_pcm=lambda _path: [0.0],
        )

        self.assertEqual(result, 0)
        messages = read_lines(stdout)
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["type"], "ready")
        self.assertIn("load_ms", messages[0])
        self.assertIn("peak_memory_mb", messages[0])
        self.assertGreaterEqual(messages[0]["load_ms"], 0)

    def test_transcribe_request_with_fake_model_returns_result(self):
        request = {"type": "transcribe", "id": 7, "pcm_path": "/tmp/does-not-matter.f32", "sample_rate": 16000}
        stdin = io.StringIO(json.dumps(request) + "\n")
        stdout = io.StringIO()
        transcriber = FakeTranscriber()
        fake_samples = [0.1] * 8000   # 0.5s at 16kHz — enough to survive 3-decimal rounding

        worker.run_worker(
            stdin, stdout, "model-dir", "vi", ["MeetGist"],
            transcriber_factory=lambda _dir: transcriber,
            read_pcm=lambda path: fake_samples,
        )

        messages = read_lines(stdout)
        self.assertEqual(messages[0]["type"], "ready")
        result = messages[1]
        self.assertEqual(result["type"], "result")
        self.assertEqual(result["id"], 7)
        self.assertEqual(result["text"], "transcribed 8000 samples")
        self.assertAlmostEqual(result["audio_seconds"], 0.5, places=3)
        self.assertIn("asr_ms", result)
        self.assertEqual(transcriber.calls[0]["language"], "vi")
        self.assertEqual(transcriber.calls[0]["hotwords"], ["MeetGist"])

    def test_bad_pcm_path_reports_an_error_reply_not_a_crash(self):
        request = {"type": "transcribe", "id": 3, "pcm_path": "/no/such/file.f32", "sample_rate": 16000}
        stdin = io.StringIO(json.dumps(request) + "\n")
        stdout = io.StringIO()
        transcriber = FakeTranscriber()

        def raising_read_pcm(_path):
            raise FileNotFoundError("no such file")

        result = worker.run_worker(
            stdin, stdout, "model-dir", None, None,
            transcriber_factory=lambda _dir: transcriber,
            read_pcm=raising_read_pcm,
        )

        self.assertEqual(result, 0)
        messages = read_lines(stdout)
        error_message = messages[1]
        self.assertEqual(error_message["type"], "error")
        self.assertEqual(error_message["id"], 3)
        self.assertIn("no such file", error_message["message"])
        self.assertEqual(transcriber.calls, [])

    def test_transcriber_exception_reports_error_reply_and_worker_keeps_running(self):
        request_ok = {"type": "transcribe", "id": 1, "pcm_path": "x", "sample_rate": 16000}
        request_bad = {"type": "transcribe", "id": 2, "pcm_path": "x", "sample_rate": 16000}
        stdin = io.StringIO(json.dumps(request_bad) + "\n" + json.dumps(request_ok) + "\n")
        stdout = io.StringIO()

        class FlakyTranscriber:
            def __init__(self):
                self.calls = 0

            def transcribe(self, audio, *, language, hotwords):
                self.calls += 1
                if self.calls == 1:
                    raise RuntimeError("simulated model crash")
                return "ok"

        transcriber = FlakyTranscriber()
        worker.run_worker(
            stdin, stdout, "model-dir", None, None,
            transcriber_factory=lambda _dir: transcriber,
            read_pcm=lambda _path: [0.1, 0.2],
        )

        messages = read_lines(stdout)
        self.assertEqual(messages[1]["type"], "error")
        self.assertEqual(messages[1]["id"], 2)
        self.assertIn("simulated model crash", messages[1]["message"])
        self.assertEqual(messages[2]["type"], "result")
        self.assertEqual(messages[2]["id"], 1)
        self.assertEqual(messages[2]["text"], "ok")

    def test_shutdown_message_stops_the_loop_without_processing_further_lines(self):
        stdin = io.StringIO(
            json.dumps({"type": "shutdown"}) + "\n"
            + json.dumps({"type": "transcribe", "id": 99, "pcm_path": "x", "sample_rate": 16000}) + "\n"
        )
        stdout = io.StringIO()
        transcriber = FakeTranscriber()

        result = worker.run_worker(
            stdin, stdout, "model-dir", None, None,
            transcriber_factory=lambda _dir: transcriber,
            read_pcm=lambda _path: [0.1],
        )

        self.assertEqual(result, 0)
        messages = read_lines(stdout)
        self.assertEqual(len(messages), 1)   # only "ready" — shutdown stopped before the transcribe line
        self.assertEqual(transcriber.calls, [])

    def test_unknown_message_type_is_ignored_not_fatal(self):
        stdin = io.StringIO(json.dumps({"type": "ping"}) + "\nnot even json\n" + json.dumps({"type": "shutdown"}) + "\n")
        stdout = io.StringIO()
        result = worker.run_worker(
            stdin, stdout, "model-dir", None, None,
            transcriber_factory=lambda _dir: FakeTranscriber(),
            read_pcm=lambda _path: [0.0],
        )
        self.assertEqual(result, 0)

    def test_hotwords_from_file_are_parsed_as_a_comma_or_newline_list(self):
        self.assertIsNone(worker._hotwords_from_file(None))
        self.assertIsNone(worker._hotwords_from_file("/no/such/hotwords.txt"))

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hotwords.txt"
            path.write_text("MeetGist, Swift\nQwen3-ASR\n", encoding="utf-8")
            self.assertEqual(worker._hotwords_from_file(str(path)), ["MeetGist", "Swift", "Qwen3-ASR"])

    def test_peak_memory_mb_never_raises(self):
        value = worker.peak_memory_mb()
        self.assertIsInstance(value, float)
        self.assertGreaterEqual(value, 0.0)


if __name__ == "__main__":
    unittest.main()
