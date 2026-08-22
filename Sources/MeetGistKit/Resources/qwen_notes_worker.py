#!/usr/bin/env python3
"""One-shot local Meeting Minutes worker for Qwen3 8B + MLX-LM."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Callable


SOURCE_CHUNK_TOKENS = 7_000
FINAL_SOURCE_TOKENS = 7_000
CHUNK_OUTPUT_TOKENS = 700
FINAL_OUTPUT_TOKENS = 3_072

LANGUAGE_RULE = """
This provider-specific language rule overrides any earlier LANGUAGE rule: use
natural Vietnamese headings and prose when Vietnamese is dominant, Simplified
Chinese when Chinese is dominant, and English otherwise. Preserve English
technical terms and never translate speaker names, identifiers, code, or product
names. Use only facts in the source; never invent owners, deadlines, decisions,
risks, or blockers.
"""

EXTRACT_INSTRUCTIONS = """
Extract a compact factual record from this transcript chunk. Preserve speakers,
timestamps, decisions, action items, owners, deadlines, risks, open questions,
and important technical details. Merge filler and repetition but do not invent
or infer facts. Output concise Markdown bullets only, without a preamble.
""" + LANGUAGE_RULE

REDUCE_INSTRUCTIONS = """
Condense these partial meeting facts. Merge duplicates without losing speakers,
timestamps, decisions, action items, owners, deadlines, risks, open questions,
or technical detail. Do not invent facts. Output concise Markdown bullets only.
""" + LANGUAGE_RULE


def token_count(text: str, tokenizer) -> int:
    return len(tokenizer.encode(text, add_special_tokens=False))


def seconds_from_throughput(tokens: int, tokens_per_second: float) -> float:
    return tokens / tokens_per_second if tokens_per_second > 0 else 0.0


def split_for_context(text: str, tokenizer, limit: int) -> list[str]:
    """Prefer transcript lines, while bounding malformed oversized lines."""
    if not text.strip():
        return []
    if token_count(text, tokenizer) <= limit:
        return [text.strip()]

    chunks: list[str] = []
    current: list[str] = []
    current_tokens = 0

    def flush() -> None:
        nonlocal current, current_tokens
        value = "\n".join(current).strip()
        if value:
            chunks.append(value)
        current = []
        current_tokens = 0

    for line in text.splitlines():
        line_tokens = tokenizer.encode(line, add_special_tokens=False)
        if len(line_tokens) > limit:
            flush()
            for start in range(0, len(line_tokens), limit):
                piece = tokenizer.decode(line_tokens[start : start + limit]).strip()
                if piece:
                    chunks.append(piece)
            continue
        separator_tokens = 1 if current else 0
        if current and current_tokens + separator_tokens + len(line_tokens) > limit:
            flush()
        current.append(line)
        current_tokens += separator_tokens + len(line_tokens)
    flush()
    return chunks


def condense_source(
    transcript: str,
    tokenizer,
    generate_text: Callable[[str, str, int], str],
    progress: Callable[[str], None],
) -> tuple[str, int]:
    if token_count(transcript, tokenizer) <= FINAL_SOURCE_TOKENS:
        return transcript, 1

    chunks = split_for_context(transcript, tokenizer, SOURCE_CHUNK_TOKENS)
    summaries: list[str] = []
    for index, chunk in enumerate(chunks):
        progress(f"Analyzing transcript chunk {index + 1} of {len(chunks)}…")
        value = generate_text(EXTRACT_INSTRUCTIONS, chunk, CHUNK_OUTPUT_TOKENS).strip()
        if not value:
            raise RuntimeError("Qwen returned an empty transcript chunk summary.")
        summaries.append(value)

    combined = "\n\n".join(summaries)
    pass_number = 1
    while token_count(combined, tokenizer) > FINAL_SOURCE_TOKENS:
        before = token_count(combined, tokenizer)
        batches = split_for_context(combined, tokenizer, SOURCE_CHUNK_TOKENS)
        reduced: list[str] = []
        for index, batch in enumerate(batches):
            progress(f"Condensing notes pass {pass_number}, batch {index + 1} of {len(batches)}…")
            value = generate_text(REDUCE_INSTRUCTIONS, batch, CHUNK_OUTPUT_TOKENS).strip()
            if not value:
                raise RuntimeError("Qwen returned an empty reduced summary.")
            reduced.append(value)
        combined = "\n\n".join(reduced)
        if token_count(combined, tokenizer) >= before:
            raise RuntimeError("Qwen could not condense the transcript within its context limit.")
        pass_number += 1
    return combined, len(chunks)


def split_output(raw: str, is_template: bool) -> tuple[str, str]:
    value = raw.strip()
    if not value:
        raise RuntimeError("Qwen returned empty meeting notes.")
    if is_template:
        return value, value
    polished_marker = "---POLISHED---"
    summary_marker = "---SUMMARY---"
    if polished_marker not in value or summary_marker not in value:
        raise RuntimeError("Qwen output did not contain the required POLISHED and SUMMARY sections.")
    body = value.split(polished_marker, 1)[1]
    polished, summary = body.split(summary_marker, 1)
    polished, summary = polished.strip(), summary.strip()
    if not polished or not summary:
        raise RuntimeError("Qwen returned an incomplete Meeting Minutes response.")
    return polished, summary


class MLXGenerator:
    def __init__(self, model_path: str):
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_sampler

        model_load_started = time.perf_counter()
        self.model, self.tokenizer = load(model_path)
        self.model_load_seconds = time.perf_counter() - model_load_started
        self._stream_generate = stream_generate
        self._sampler = make_sampler(temp=0.7, top_p=0.8, top_k=20, min_p=0.0)
        self.peak_memory_gb = 0.0
        self.prompt_tokens = 0
        self.generation_tokens = 0
        self.prefill_seconds = 0.0
        self.generation_seconds = 0.0

    def __call__(self, instructions: str, source: str, max_tokens: int) -> str:
        prompt = self.tokenizer.apply_chat_template(
            [
                {"role": "system", "content": instructions},
                {"role": "user", "content": source},
            ],
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        pieces: list[str] = []
        last = None
        for response in self._stream_generate(
            self.model,
            self.tokenizer,
            prompt,
            max_tokens=max_tokens,
            sampler=self._sampler,
            prefill_step_size=1_024,
        ):
            pieces.append(response.text)
            last = response
        if last is not None:
            self.peak_memory_gb = max(self.peak_memory_gb, float(last.peak_memory))
            self.prompt_tokens += int(last.prompt_tokens)
            self.generation_tokens += int(last.generation_tokens)
            # MLX-LM measures prefill until the first generated token, then
            # starts a new timer for decoding. Recover each duration from those
            # public metrics so map/reduce calls can be accumulated faithfully.
            self.prefill_seconds += seconds_from_throughput(
                int(last.prompt_tokens), float(last.prompt_tps)
            )
            self.generation_seconds += seconds_from_throughput(
                int(last.generation_tokens), float(last.generation_tps)
            )
        return "".join(pieces).strip()


def emit_progress(message: str) -> None:
    print(json.dumps({"progress": message}, ensure_ascii=False), flush=True)


def run(request_path: Path, output_path: Path, model_path: str) -> None:
    request = json.loads(request_path.read_text(encoding="utf-8"))
    transcript = str(request.get("transcript", "")).strip()
    instructions = str(request.get("instructions", "")).strip()
    is_template = bool(request.get("isTemplate", False))
    if not transcript:
        raise RuntimeError("transcript.md is empty.")
    if not instructions:
        raise RuntimeError("Meeting Notes instructions are empty.")

    started = time.perf_counter()
    emit_progress("Loading Qwen3 8B into unified memory…")
    generator = MLXGenerator(model_path)
    emit_progress("Preparing transcript for local generation…")
    source, source_chunks = condense_source(
        transcript, generator.tokenizer, generator, emit_progress
    )
    emit_progress("Writing Meeting Minutes & Summary with Qwen…")
    raw = generator(instructions + "\n" + LANGUAGE_RULE, source, FINAL_OUTPUT_TOKENS)
    polished, summary = split_output(raw, is_template)
    generation_tokens_per_second = (
        generator.generation_tokens / generator.generation_seconds
        if generator.generation_seconds > 0
        else 0.0
    )

    result = {
        "polished": polished,
        "summary": summary,
        "metrics": {
            "elapsedSeconds": time.perf_counter() - started,
            "modelLoadSeconds": generator.model_load_seconds,
            "prefillSeconds": generator.prefill_seconds,
            "generationSeconds": generator.generation_seconds,
            "generationTokensPerSecond": generation_tokens_per_second,
            "peakMemoryGB": generator.peak_memory_gb,
            "promptTokens": generator.prompt_tokens,
            "generationTokens": generator.generation_tokens,
            "sourceChunks": source_chunks,
        },
    }
    temporary = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, output_path)


def self_test() -> None:
    class FakeTokenizer:
        def encode(self, text, add_special_tokens=False):
            return [ord(character) for character in text]

        def decode(self, values):
            return "".join(chr(value) for value in values)

    tokenizer = FakeTokenizer()
    long_text = "\n".join(
        f"[00:{index % 60:02d}] Speaker: decision {index} " + ("x" * 100)
        for index in range(180)
    )
    calls: list[str] = []

    def fake_generate(instructions: str, source: str, max_tokens: int) -> str:
        calls.append(instructions)
        return "- retained fact " + source[:160]

    source, count = condense_source(long_text, tokenizer, fake_generate, lambda _: None)
    assert count > 1
    assert len(source) <= FINAL_SOURCE_TOKENS
    assert len(calls) > 1
    assert seconds_from_throughput(120, 40) == 3
    assert seconds_from_throughput(120, 0) == 0
    polished, summary = split_output(
        "---POLISHED---\n# Minutes\n---SUMMARY---\n## TL;DR", False
    )
    assert polished == "# Minutes" and summary == "## TL;DR"
    print("qwen_notes_worker self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--model")
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return
    if not arguments.request or not arguments.output or not arguments.model:
        parser.error("--request, --output, and --model are required")
    run(arguments.request, arguments.output, arguments.model)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Local Qwen Notes failed: {error}", file=sys.stderr, flush=True)
        raise
