#!/usr/bin/env python3
"""One-shot local Meeting Minutes worker for Qwen3 4B Instruct + MLX-LM.

Two strategies, chosen by source token count:
  - direct:     transcript fits DIRECT_SOURCE_TOKENS -> one final generation call.
  - map/reduce: transcript is longer -> extract per-chunk facts (map), condense
                repeatedly under a shrink invariant (reduce), then a final call.

Token budgets are passed in from the Swift side (LocalNotesModelConfig) so this
file has no model-specific magic numbers of its own; see
Sources/MeetGistKit/LocalNotesRuntimeManager.swift.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Callable, NamedTuple


# Intermediate extract/reduce passes deliberately keep the transcript's own
# source language rather than translating early — only the final generation
# call (using the caller-supplied `instructions`, which already embeds the
# configured output language via Prompts.polished(language:) on the Swift
# side) translates, so multi-pass condensation never compounds translation
# drift across chunks.
SOURCE_LANGUAGE_RULE = """
Use only facts in the source; never invent owners, deadlines, decisions, risks,
or blockers. Preserve English technical terms and never translate speaker
names, identifiers, code, or product names. Keep the source's dominant
language for this intermediate step — do not translate yet.
"""

EXTRACT_INSTRUCTIONS = """
Extract a compact factual record from this transcript chunk. Preserve speakers,
timestamps, decisions, action items, owners, deadlines, risks, open questions,
and important technical details. Merge filler and repetition but do not invent
or infer facts. Output concise Markdown bullets only, without a preamble.
""" + SOURCE_LANGUAGE_RULE

REDUCE_INSTRUCTIONS = """
Condense these partial meeting facts. Merge duplicates without losing speakers,
timestamps, decisions, action items, owners, deadlines, risks, open questions,
or technical detail. Do not invent facts. Output concise Markdown bullets only.
""" + SOURCE_LANGUAGE_RULE


class TokenBudgets(NamedTuple):
    """Mirrors LocalNotesModelConfig on the Swift side. No values are hardcoded
    here beyond the argparse defaults, which only exist for --self-test and
    direct CLI use; normal runs always receive explicit flags from Swift."""

    direct_source_tokens: int
    map_source_tokens: int
    map_output_tokens: int
    reduce_source_tokens: int
    reduce_output_tokens: int
    final_output_tokens: int


class CallCounters:
    """Phase 1 baseline instrumentation: counts LLM calls by role so old and
    new architectures (7K map/reduce vs 24-32K direct) can be compared."""

    def __init__(self) -> None:
        self.map_calls = 0
        self.reduce_calls = 0
        self.final_calls = 0

    @property
    def total(self) -> int:
        return self.map_calls + self.reduce_calls + self.final_calls


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
    budgets: TokenBudgets,
    generate_text: Callable[[str, str, int], str],
    progress: Callable[[str], None],
    counters: CallCounters,
) -> tuple[str, int]:
    """Long-transcript fallback: map (extract) then recursively reduce
    (condense) until the combined notes fit within direct_source_tokens.
    Enforces a shrink invariant on every reduce pass so this cannot loop
    forever on a transcript the model can't compress further."""
    chunks = split_for_context(transcript, tokenizer, budgets.map_source_tokens)
    summaries: list[str] = []
    for index, chunk in enumerate(chunks):
        progress(f"Analyzing transcript chunk {index + 1} of {len(chunks)}…")
        value = generate_text(EXTRACT_INSTRUCTIONS, chunk, budgets.map_output_tokens).strip()
        counters.map_calls += 1
        if not value:
            raise RuntimeError("Qwen returned an empty transcript chunk summary.")
        summaries.append(value)

    combined = "\n\n".join(summaries)
    pass_number = 1
    while token_count(combined, tokenizer) > budgets.direct_source_tokens:
        before = token_count(combined, tokenizer)
        batches = split_for_context(combined, tokenizer, budgets.reduce_source_tokens)
        reduced: list[str] = []
        for index, batch in enumerate(batches):
            progress(f"Condensing notes pass {pass_number}, batch {index + 1} of {len(batches)}…")
            value = generate_text(REDUCE_INSTRUCTIONS, batch, budgets.reduce_output_tokens).strip()
            counters.reduce_calls += 1
            if not value:
                raise RuntimeError("Qwen returned an empty reduced summary.")
            reduced.append(value)
        combined = "\n\n".join(reduced)
        if token_count(combined, tokenizer) >= before:
            raise RuntimeError("Qwen could not condense the transcript within its context limit.")
        pass_number += 1
    return combined, len(chunks)


def prepare_source(
    transcript: str,
    tokenizer,
    budgets: TokenBudgets,
    generate_text: Callable[[str, str, int], str],
    progress: Callable[[str], None],
    counters: CallCounters,
) -> tuple[str, int, bool]:
    """Strategy selection: direct context for normal meetings, map/reduce
    fallback only for transcripts that exceed the direct-context budget."""
    if token_count(transcript, tokenizer) <= budgets.direct_source_tokens:
        return transcript, 1, True
    source, source_chunks = condense_source(
        transcript, tokenizer, budgets, generate_text, progress, counters
    )
    return source, source_chunks, False


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
    def __init__(self, model_path: str, temperature: float, top_p: float, top_k: int):
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_sampler

        model_load_started = time.perf_counter()
        self.model, self.tokenizer = load(model_path)
        self.model_load_seconds = time.perf_counter() - model_load_started
        self._stream_generate = stream_generate
        self._sampler = make_sampler(temp=temperature, top_p=top_p, top_k=top_k, min_p=0.0)
        self.peak_memory_gb = 0.0
        self.prompt_tokens = 0
        self.generation_tokens = 0
        self.prefill_seconds = 0.0
        self.generation_seconds = 0.0

    def __call__(self, instructions: str, source: str, max_tokens: int) -> str:
        # Qwen3-4B-Instruct-2507 is a non-thinking-only model: it has no
        # `enable_thinking` switch (unlike Qwen3-8B's hybrid thinking mode), so
        # the chat template is applied without that argument.
        prompt = self.tokenizer.apply_chat_template(
            [
                {"role": "system", "content": instructions},
                {"role": "user", "content": source},
            ],
            tokenize=False,
            add_generation_prompt=True,
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


def run(request_path: Path, output_path: Path, model_path: str, budgets: TokenBudgets,
        temperature: float, top_p: float, top_k: int) -> None:
    wall_clock_started = time.perf_counter()
    request = json.loads(request_path.read_text(encoding="utf-8"))
    transcript = str(request.get("transcript", "")).strip()
    instructions = str(request.get("instructions", "")).strip()
    is_template = bool(request.get("isTemplate", False))
    if not transcript:
        raise RuntimeError("transcript.md is empty.")
    if not instructions:
        raise RuntimeError("Meeting Notes instructions are empty.")

    started = time.perf_counter()
    emit_progress("Loading Qwen3 4B into unified memory…")
    generator = MLXGenerator(model_path, temperature, top_p, top_k)
    emit_progress("Preparing transcript for local generation…")
    counters = CallCounters()
    source, source_chunks, used_direct_context = prepare_source(
        transcript, generator.tokenizer, budgets, generator, emit_progress, counters
    )
    emit_progress("Writing Meeting Minutes & Summary with Qwen…")
    # `instructions` already carries the final-output language rule (from
    # Prompts.polished(language:)/Prompts.templatedNotes(language:) on the
    # Swift side) — no separate rule appended here to avoid contradicting it.
    raw = generator(instructions, source, budgets.final_output_tokens)
    counters.final_calls += 1
    polished, summary = split_output(raw, is_template)
    generation_tokens_per_second = (
        generator.generation_tokens / generator.generation_seconds
        if generator.generation_seconds > 0
        else 0.0
    )
    total_generation_seconds = time.perf_counter() - started
    wall_clock_seconds = time.perf_counter() - wall_clock_started

    result = {
        "polished": polished,
        "summary": summary,
        "metrics": {
            "elapsedSeconds": total_generation_seconds,
            "modelLoadSeconds": generator.model_load_seconds,
            "prefillSeconds": generator.prefill_seconds,
            "generationSeconds": generator.generation_seconds,
            "generationTokensPerSecond": generation_tokens_per_second,
            "peakMemoryGB": generator.peak_memory_gb,
            "promptTokens": generator.prompt_tokens,
            "generationTokens": generator.generation_tokens,
            "sourceChunks": source_chunks,
            "wallClockSeconds": wall_clock_seconds,
            "numberOfLLMCalls": counters.total,
            "mapCalls": counters.map_calls,
            "reduceCalls": counters.reduce_calls,
            "finalCalls": counters.final_calls,
            "usedDirectContext": used_direct_context,
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
    budgets = TokenBudgets(
        direct_source_tokens=1_000,
        map_source_tokens=400,
        map_output_tokens=700,
        reduce_source_tokens=400,
        reduce_output_tokens=700,
        final_output_tokens=3_072,
    )
    long_text = "\n".join(
        f"[00:{index % 60:02d}] Speaker: decision {index} " + ("x" * 100)
        for index in range(180)
    )
    calls: list[str] = []

    def fake_generate(instructions: str, source: str, max_tokens: int) -> str:
        calls.append(instructions)
        return "- retained fact " + source[:160]

    counters = CallCounters()
    source, count = condense_source(
        long_text, tokenizer, budgets, fake_generate, lambda _: None, counters
    )
    assert count > 1
    assert len(source) <= budgets.direct_source_tokens
    assert len(calls) > 1
    assert counters.map_calls == count
    assert counters.reduce_calls >= 1

    # Direct-context strategy selection: short transcript takes no map/reduce calls.
    direct_counters = CallCounters()
    direct_source, direct_chunks, used_direct = prepare_source(
        "short transcript", tokenizer, budgets, fake_generate, lambda _: None, direct_counters
    )
    assert used_direct is True
    assert direct_chunks == 1
    assert direct_counters.total == 0
    assert direct_source == "short transcript"

    # Long transcript takes the map/reduce path.
    long_counters = CallCounters()
    _, _, used_direct_long = prepare_source(
        long_text, tokenizer, budgets, fake_generate, lambda _: None, long_counters
    )
    assert used_direct_long is False
    assert long_counters.map_calls > 0

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
    parser.add_argument("--direct-source-tokens", type=int, default=28_000)
    parser.add_argument("--map-source-tokens", type=int, default=6_000)
    parser.add_argument("--map-output-tokens", type=int, default=700)
    parser.add_argument("--reduce-source-tokens", type=int, default=6_000)
    parser.add_argument("--reduce-output-tokens", type=int, default=700)
    parser.add_argument("--final-output-tokens", type=int, default=3_072)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.8)
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return
    if not arguments.request or not arguments.output or not arguments.model:
        parser.error("--request, --output, and --model are required")
    budgets = TokenBudgets(
        direct_source_tokens=arguments.direct_source_tokens,
        map_source_tokens=arguments.map_source_tokens,
        map_output_tokens=arguments.map_output_tokens,
        reduce_source_tokens=arguments.reduce_source_tokens,
        reduce_output_tokens=arguments.reduce_output_tokens,
        final_output_tokens=arguments.final_output_tokens,
    )
    run(arguments.request, arguments.output, arguments.model, budgets,
        arguments.temperature, arguments.top_p, arguments.top_k)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Local Qwen Notes failed: {error}", file=sys.stderr, flush=True)
        raise
