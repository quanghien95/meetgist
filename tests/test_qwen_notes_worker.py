import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

WORKER_PATH = Path(__file__).parents[1] / "Sources" / "MeetGistKit" / "Resources" / "qwen_notes_worker.py"
SPEC = importlib.util.spec_from_file_location("qwen_notes_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


class FakeTokenizer:
    """One token per character — makes token budgets easy to reason about."""

    def encode(self, text, add_special_tokens=False):
        return [ord(character) for character in text]

    def decode(self, values):
        return "".join(chr(value) for value in values)

    def apply_chat_template(self, messages, tokenize=False, add_generation_prompt=True):
        return "\n".join(m["content"] for m in messages)


def small_budgets(direct=200, map_src=80, reduce_src=80, map_out=64, reduce_out=64, final_out=256):
    return worker.TokenBudgets(
        direct_source_tokens=direct,
        map_source_tokens=map_src,
        map_output_tokens=map_out,
        reduce_source_tokens=reduce_src,
        reduce_output_tokens=reduce_out,
        final_output_tokens=final_out,
    )


class PrepareSourceTests(unittest.TestCase):
    """Phase 3/4: direct-context vs map/reduce strategy selection."""

    def test_transcript_below_direct_threshold_uses_single_call_no_map_reduce(self):
        tokenizer = FakeTokenizer()
        budgets = small_budgets(direct=200)
        transcript = "[00:01] Alice: short meeting notes here."
        calls = []

        def generate(instructions, source, max_tokens):
            calls.append(instructions)
            return "should not be called"

        counters = worker.CallCounters()
        source, chunks, used_direct = worker.prepare_source(
            transcript, tokenizer, budgets, generate, lambda _: None, counters
        )

        self.assertTrue(used_direct)
        self.assertEqual(chunks, 1)
        self.assertEqual(source, transcript)
        self.assertEqual(len(calls), 0)
        self.assertEqual(counters.total, 0)

    def test_transcript_above_direct_threshold_uses_map_reduce(self):
        tokenizer = FakeTokenizer()
        budgets = small_budgets(direct=100, map_src=40, reduce_src=40)
        transcript = "\n".join(
            f"[00:{i:02d}] Speaker: decision {i} " + ("x" * 60) for i in range(20)
        )

        def generate(instructions, source, max_tokens):
            return "- fact " + source[:10]

        counters = worker.CallCounters()
        source, chunks, used_direct = worker.prepare_source(
            transcript, tokenizer, budgets, generate, lambda _: None, counters
        )

        self.assertFalse(used_direct)
        self.assertGreater(chunks, 1)
        self.assertGreater(counters.map_calls, 0)
        self.assertLessEqual(worker.token_count(source, tokenizer), budgets.direct_source_tokens)

    def test_recursive_reduction_enforces_shrink_invariant(self):
        tokenizer = FakeTokenizer()
        budgets = small_budgets(direct=50, map_src=30, reduce_src=30)
        transcript = "\n".join(f"[00:{i:02d}] Speaker: fact {i} filler" for i in range(40))

        def generate(instructions, source, max_tokens):
            # Each reduce call must shrink content, otherwise condense_source
            # must raise rather than loop forever.
            return source[: max(1, len(source) // 3)]

        counters = worker.CallCounters()
        source, chunks = worker.condense_source(
            transcript, tokenizer, budgets, generate, lambda _: None, counters
        )
        self.assertLessEqual(worker.token_count(source, tokenizer), budgets.direct_source_tokens)
        self.assertGreater(counters.reduce_calls, 0)

    def test_reduction_that_does_not_shrink_raises(self):
        tokenizer = FakeTokenizer()
        budgets = small_budgets(direct=10, map_src=30, reduce_src=30)
        transcript = "\n".join(f"[00:{i:02d}] Speaker: fact {i} filler text" for i in range(40))

        def generate(instructions, source, max_tokens):
            # Echoes back input unchanged -> combined text never shrinks.
            return source

        counters = worker.CallCounters()
        with self.assertRaises(RuntimeError):
            worker.condense_source(transcript, tokenizer, budgets, generate, lambda _: None, counters)


class SplitOutputTests(unittest.TestCase):
    def test_empty_transcript_raises_before_generation(self):
        request_path = Path(tempfile.mktemp(suffix=".json"))
        output_path = Path(tempfile.mktemp(suffix=".json"))
        request_path.write_text(json.dumps({"transcript": "   ", "instructions": "x", "isTemplate": False}))
        try:
            with self.assertRaises(RuntimeError):
                worker.run(request_path, output_path, "unused-model-path", small_budgets(), 0.7, 0.8, 20)
        finally:
            request_path.unlink(missing_ok=True)

    def test_malformed_response_missing_polished_marker_raises(self):
        with self.assertRaises(RuntimeError):
            worker.split_output("---SUMMARY---\nonly summary", is_template=False)

    def test_malformed_response_missing_summary_marker_raises(self):
        with self.assertRaises(RuntimeError):
            worker.split_output("---POLISHED---\nonly polished", is_template=False)

    def test_empty_model_response_raises(self):
        with self.assertRaises(RuntimeError):
            worker.split_output("   ", is_template=False)

    def test_template_mode_returns_raw_output_for_both_sections(self):
        polished, summary = worker.split_output("# Filled template", is_template=True)
        self.assertEqual(polished, "# Filled template")
        self.assertEqual(summary, "# Filled template")

    def test_well_formed_output_splits_cleanly(self):
        polished, summary = worker.split_output(
            "---POLISHED---\n# Minutes\n- decision A\n---SUMMARY---\n## TL;DR\n- action A",
            is_template=False,
        )
        self.assertEqual(polished, "# Minutes\n- decision A")
        self.assertEqual(summary, "## TL;DR\n- action A")


class MultilingualPreservationTests(unittest.TestCase):
    """Vietnamese/Chinese/mixed content must survive chunk/reduce untouched by
    naive ASCII-oriented splitting, and instructions must include the language
    rule in every map/reduce/final call."""

    def test_split_for_context_preserves_vietnamese_and_chinese_text(self):
        tokenizer = FakeTokenizer()
        text = "[00:01] An: chúng ta cần chốt phương án 决定 A/B 测试。"
        chunks = worker.split_for_context(text, tokenizer, limit=1000)
        self.assertEqual(chunks, [text])

    def test_source_language_rule_present_in_extract_and_reduce_instructions(self):
        # Intermediate map/reduce passes keep the transcript's own language
        # rather than translating early — only the final call (using the
        # caller-supplied, already-language-configured `instructions`)
        # translates. See run()'s call to generator(instructions, ...).
        self.assertIn("do not translate yet", worker.EXTRACT_INSTRUCTIONS)
        self.assertIn("do not translate yet", worker.REDUCE_INSTRUCTIONS)
        self.assertIn("never invent owners, deadlines, decisions",
                       worker.EXTRACT_INSTRUCTIONS.lower())


class CallCounterTests(unittest.TestCase):
    """Phase 1 instrumentation: map/reduce/final counts must be distinguishable."""

    def test_counters_track_each_call_kind_independently(self):
        counters = worker.CallCounters()
        counters.map_calls = 3
        counters.reduce_calls = 2
        counters.final_calls = 1
        self.assertEqual(counters.total, 6)


if __name__ == "__main__":
    unittest.main()
