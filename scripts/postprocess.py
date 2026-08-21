#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Upload audio tracks to Gemini and write transcript.md + polished.md + summary.md.

Uses two API calls to avoid output truncation:
  1. Audio -> TRANSCRIPT (verbatim, with timestamps)
  2. TRANSCRIPT text -> POLISHED + SUMMARY (text-only, no audio)

Usage: postprocess.py <session_dir>
"""
import os
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

# Homebrew's bin is absent from the minimal PATH that Shortcuts.app, launchd, and a
# bare `python postprocess.py` hand us. transcribe_meeting.sh exports it, but this
# module must not depend on being launched through the wrapper: without it, the
# missing ffmpeg only surfaces after the audio upload has already been paid for.
for _bin in ("/opt/homebrew/bin", "/usr/local/bin"):
    if os.path.isdir(_bin) and _bin not in os.environ.get("PATH", "").split(os.pathsep):
        os.environ["PATH"] = _bin + os.pathsep + os.environ.get("PATH", "")

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE / ".env"
load_dotenv(ENV_FILE)
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
GEMINI_FALLBACK_MODEL = os.getenv("GEMINI_FALLBACK_MODEL", "gemini-pro-latest")
TRANSCRIPT_PROVIDER = os.getenv("TRANSCRIPT_PROVIDER", "auto").lower()
OPENAI_TRANSCRIBE_MODEL = os.getenv(
    "OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe"
)
OPENAI_TRANSCRIBE_FALLBACK_MODEL = os.getenv(
    "OPENAI_TRANSCRIBE_FALLBACK_MODEL", "gpt-4o-transcribe"
)
OPENAI_TRANSCRIBE_PROMPT = os.getenv("OPENAI_TRANSCRIBE_PROMPT", "")
OPENAI_SINGLE_SPEAKER_LABEL = os.getenv("OPENAI_SINGLE_SPEAKER_LABEL", "Speaker 1")
OPENAI_CHUNK_SECONDS = int(os.getenv("OPENAI_CHUNK_SECONDS", "600"))
OPENAI_CHUNK_BITRATE = os.getenv("OPENAI_CHUNK_BITRATE", "32k")
OPENAI_MIN_MEAN_VOLUME_DB = float(os.getenv("OPENAI_MIN_MEAN_VOLUME_DB", "-70"))
OPENAI_MAX_UPLOAD_MB = float(os.getenv("OPENAI_MAX_UPLOAD_MB", "25"))
GEMINI_AUDIO_REQUEST_MAX_MB = float(os.getenv("GEMINI_AUDIO_REQUEST_MAX_MB", "20"))
OPENAI_FILE_THRESHOLD_RATIO = float(os.getenv("OPENAI_FILE_THRESHOLD_RATIO", "0.8"))
GEMINI_CHUNK_SECONDS = int(os.getenv("GEMINI_CHUNK_SECONDS", "600"))
GEMINI_CHUNK_MIN_DURATION_SECONDS = int(
    os.getenv("GEMINI_CHUNK_MIN_DURATION_SECONDS", "1800")
)
GEMINI_MODELS_USED: dict[str, str] = {}
OPENAI_MODELS_USED: list[str] = []

# ---------------------------------------------------------------------------
# Prompt for call 1: audio -> transcript only
# ---------------------------------------------------------------------------

def build_transcript_prompt(
    mic_exists: bool,
    system_exists: bool,
    segment_offset_seconds: float | None = None,
) -> str:
    if mic_exists and system_exists:
        track_desc = """Two synchronized audio tracks are attached:
- First file (mic.m4a): MY microphone — attribute speech here to "Me".
- Second file (system.m4a): system audio — other participants speaking.
Both start at the same moment and have the same duration."""
        speaker_rule = 'Speech on mic.m4a = "Me". On system.m4a, distinguish voices as "Participant 1", "Participant 2", etc.; use names when participants self-introduce or are addressed by name.'
    else:
        track_desc = """One audio track is attached containing a meeting recording.
Distinguish speakers as "Speaker 1", "Speaker 2", etc.
When participants self-introduce or are addressed by name, use those names instead of "Speaker N"."""
        speaker_rule = 'Distinguish voices as "Speaker 1", "Speaker 2", etc. When participants self-introduce or are addressed by name, use those names instead.'

    segment_note = ""
    if segment_offset_seconds is not None:
        segment_note = f"""
This audio is one segment of a longer recording. The segment starts at
{format_timestamp(segment_offset_seconds)} in the full recording. Use timestamps
relative to this segment, starting at [00:00]; the script will convert them back
to full-recording timestamps."""

    return f"""{track_desc}
{segment_note}

Transcribe this meeting VERBATIM. Output ONLY the transcript in this format:

---TRANSCRIPT---
[MM:SS] Speaker: verbatim speech
[MM:SS] Speaker: verbatim speech
...

Rules:
- Preserve the speaker's original language verbatim. Do not translate. If a
  speaker mixes English and Chinese in one utterance, keep both.
- {speaker_rule}
- Use [MM:SS] timestamps (or [HH:MM:SS] for meetings longer than one hour).
- Only include lines with actual spoken content. Skip long silences.
- Be THOROUGH — transcribe every utterance. Do not summarize or skip material.
- Output ONLY the ---TRANSCRIPT--- section. No summary, no commentary.
"""

# ---------------------------------------------------------------------------
# Prompt for call 2: transcript text -> polished + summary
# ---------------------------------------------------------------------------

POLISHED_PROMPT = """Below is a verbatim meeting transcript. Based on it, produce two sections.

First, decide a LANGUAGE:
- If the dominant spoken language in the transcript is Chinese (Mandarin or
  Cantonese, in any script), LANGUAGE = Simplified Chinese (简体中文).
- Otherwise (English, mixed, or any other language), LANGUAGE = English.

Output in EXACTLY this format:

---POLISHED---
# [Meeting Title or "Meeting Minutes"]

## Smart Summary
(2-3 sentence overview in LANGUAGE)

## Recording Information
- **Duration**: ...
- **Number of participants**: ...
- **Content type**: ...

## [Topic sections — create headings based on meeting flow]
### [Section Title]
- **Speaker Name**: cleaned-up version of what they said (no ums, ahs, filler words, repetitions, or broken sentences; meaning preserved, no new info added)
...

## Chapter Summary
[MM:SS] **Chapter Title** — brief description of what happened in this segment
...

## Selected Quotes
- "..." (Speaker Name) — (Strategic insight / Thinking inspiration / Key decision)
...

## To-do Items
- [ ] Owner - task description

## Per-Speaker Stance
- **Speaker Name**:
  - Claimed / Argued: what positions, arguments, or opinions they expressed
  - Committed to: what actions or follow-ups they agreed to take on
...

---SUMMARY---
## TL;DR
(2-4 sentences in LANGUAGE)

## Key Decisions
- ... (in LANGUAGE)

## Action Items
- [ ] Owner - task (due: date if mentioned)   <- in LANGUAGE

## Open Questions / Follow-ups
- ... (in LANGUAGE)

## Notable Context
(anything important for future reference, in LANGUAGE)

Rules:
- POLISHED: same content as the transcript but disfluencies removed, repeats
  merged, broken sentences healed — make it clear, detailed, and ready for
  reading. Meaning preserved, no new information added.
  Write entirely in LANGUAGE.
  If LANGUAGE is Simplified Chinese: use natural Chinese section headings
  (e.g. "📑 智能摘要", "📋 待办事项", "✨ 精选语录", "📅 章节摘要", "👥 各发言人立场").
  If LANGUAGE is English: use English section headings.
- SUMMARY (everything after ---SUMMARY---): write entirely in LANGUAGE,
  headings included. Do NOT mix languages.
  If LANGUAGE is Simplified Chinese: translate the section headings too —
  "## 摘要 / ## 关键决定 / ## 行动项 / ## 待解决问题 / ## 补充背景" — and write all
  content in 简体中文. Use 简体, never 繁體.
  If LANGUAGE is English: everything in English.
- Consistency: the entire output (every heading, label, and body line) must be in
  one LANGUAGE. Never put an English heading on Chinese content or vice versa.
- Be polished and readable on the POLISHED section; be punchy on the summary.
"""


def notify(message: str) -> None:
    try:
        os.system(
            f'osascript -e \'display notification "{message}" with title "meetgist"\' '
            "2>/dev/null"
        )
    except Exception:
        pass


def audio_duration_seconds(path: Path) -> float | None:
    try:
        result = subprocess.run(
            ["afinfo", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            match = re.search(r"estimated duration:\s+([0-9.]+)\s+sec", result.stdout)
            if match:
                return float(match.group(1))
    except FileNotFoundError:
        pass

    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return float(result.stdout.strip())
    except (FileNotFoundError, ValueError):
        pass

    return None


def audio_mean_volume_db(path: Path) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-nostats",
                "-i",
                str(path),
                "-af",
                "volumedetect",
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None

    match = re.search(r"mean_volume:\s+(-?[0-9.]+) dB", result.stderr)
    if not match:
        return None
    return float(match.group(1))


def filter_low_signal_tracks(tracks: list[tuple[str, Path]]) -> list[tuple[str, Path]]:
    if len(tracks) <= 1:
        return tracks

    kept: list[tuple[str, Path]] = []
    for label, path in tracks:
        mean_volume = audio_mean_volume_db(path)
        if mean_volume is not None and mean_volume <= OPENAI_MIN_MEAN_VOLUME_DB:
            print(
                f"warning: skipping {path.name}; mean volume {mean_volume:.1f} dB "
                f"is below {OPENAI_MIN_MEAN_VOLUME_DB:.1f} dB",
                flush=True,
            )
            continue
        kept.append((label, path))

    return kept or tracks


def format_timestamp(seconds: float | int | None) -> str:
    total = max(0, int(seconds or 0))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def field(obj, name: str, default=None):
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def speaker_label(label: str, mic_exists: bool, system_exists: bool) -> str:
    if label == "mic":
        return "Me"
    if mic_exists and system_exists:
        return "Participant 1"
    return OPENAI_SINGLE_SPEAKER_LABEL


def use_openai_transcriber(tracks: list[tuple[str, Path]]) -> bool:
    valid_providers = {"auto", "gemini", "openai"}
    if TRANSCRIPT_PROVIDER not in valid_providers:
        raise SystemExit(
            f"TRANSCRIPT_PROVIDER must be one of {', '.join(sorted(valid_providers))}; "
            f"got {TRANSCRIPT_PROVIDER!r}"
        )

    if TRANSCRIPT_PROVIDER == "gemini":
        return False
    if TRANSCRIPT_PROVIDER == "openai":
        return True

    if not tracks:
        return False

    largest_mb = max(path.stat().st_size for _, path in tracks) / 1_000_000
    threshold_mb = GEMINI_AUDIO_REQUEST_MAX_MB * OPENAI_FILE_THRESHOLD_RATIO
    if largest_mb < threshold_mb:
        return False

    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        print(
            f"warning: largest file is {largest_mb:.1f} MB, but OPENAI_API_KEY is not set; "
            f"using Gemini {GEMINI_MODEL}",
            flush=True,
        )
        return False

    return True


def wait_active(client: genai.Client, file_obj) -> object:
    while file_obj.state.name == "PROCESSING":
        time.sleep(2)
        file_obj = client.files.get(name=file_obj.name)
    if file_obj.state.name != "ACTIVE":
        raise SystemExit(f"file {file_obj.name} failed to process: {file_obj.state.name}")
    return file_obj


def check_finish_reason(response, label: str) -> None:
    """Warn if the response was truncated."""
    try:
        candidates = getattr(response, 'candidates', [])
        if candidates:
            reason = getattr(candidates[0], 'finish_reason', None)
            if reason and reason.name != "STOP":
                print(f"warning: {label} finish_reason={reason.name} (may be truncated)", flush=True)
    except Exception:
        pass


def finish_reason_name(response) -> str | None:
    try:
        candidates = getattr(response, "candidates", [])
        if candidates:
            reason = getattr(candidates[0], "finish_reason", None)
            return getattr(reason, "name", None)
    except Exception:
        return None
    return None


def candidate_models(primary: str, fallback: str | None) -> list[str]:
    models = [primary]
    if fallback and fallback not in models:
        models.append(fallback)
    return models


def generate_with_gemini(client: genai.Client, label: str, **kwargs):
    errors: list[str] = []
    for model in candidate_models(GEMINI_MODEL, GEMINI_FALLBACK_MODEL):
        try:
            print(f"{label} with Gemini {model}...", flush=True)
            response = client.models.generate_content(model=model, **kwargs)
            GEMINI_MODELS_USED[label] = model
            return response
        except Exception as exc:
            errors.append(f"{model}: {exc}")
            print(f"warning: Gemini {model} failed for {label}: {exc}", flush=True)

    raise SystemExit("all Gemini models failed:\n" + "\n".join(errors))


def parse_timestamp_seconds(timestamp: str) -> int | None:
    parts = timestamp.split(":")
    if len(parts) == 2:
        minutes, seconds = parts
        return int(minutes) * 60 + int(seconds)
    if len(parts) == 3:
        hours, minutes, seconds = parts
        return int(hours) * 3600 + int(minutes) * 60 + int(seconds)
    return None


def offset_transcript_timestamps(transcript: str, offset_seconds: float) -> str:
    lines: list[str] = []
    timestamp_pattern = re.compile(r"^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*(.*)$")
    for line in transcript.splitlines():
        match = timestamp_pattern.match(line.strip())
        if not match:
            if line.strip():
                lines.append(line.rstrip())
            continue

        seconds = parse_timestamp_seconds(match.group(1))
        if seconds is None:
            lines.append(line.rstrip())
            continue

        lines.append(f"[{format_timestamp(offset_seconds + seconds)}] {match.group(2)}")
    return "\n".join(lines)


def should_chunk_gemini(tracks: list[tuple[str, Path]]) -> bool:
    if GEMINI_CHUNK_SECONDS <= 0:
        return False

    durations = [
        duration
        for _, path in tracks
        if (duration := audio_duration_seconds(path)) is not None
    ]
    if not durations:
        return False

    return max(durations) > GEMINI_CHUNK_MIN_DURATION_SECONDS


def split_audio_for_gemini(
    tracks: list[tuple[str, Path]], work_dir: Path
) -> list[tuple[float, list[tuple[str, Path]]]]:
    duration = max(audio_duration_seconds(path) or 0 for _, path in tracks)
    chunks: list[tuple[float, list[tuple[str, Path]]]] = []
    start = 0.0
    chunk_index = 0

    while start < duration:
        chunk_tracks: list[tuple[str, Path]] = []
        chunk_dir = work_dir / f"chunk-{chunk_index:04d}"
        chunk_dir.mkdir(parents=True, exist_ok=True)

        for label, path in tracks:
            output = chunk_dir / f"{label}.m4a"
            result = subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-ss",
                    f"{start:.3f}",
                    "-t",
                    str(GEMINI_CHUNK_SECONDS),
                    "-i",
                    str(path),
                    "-vn",
                    "-map",
                    "0:a:0",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "64k",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                raise SystemExit(
                    f"ffmpeg chunk failed for {path.name} at "
                    f"{format_timestamp(start)}: {result.stderr.strip()}"
                )
            if output.exists() and output.stat().st_size > 0:
                chunk_tracks.append((label, output))

        if chunk_tracks:
            chunks.append((start, chunk_tracks))

        chunk_index += 1
        start += GEMINI_CHUNK_SECONDS

    return chunks


def transcribe_with_gemini_once(
    client: genai.Client,
    tracks: list[tuple[str, Path]],
    mic_exists: bool,
    system_exists: bool,
    segment_offset_seconds: float | None = None,
) -> tuple[str, list]:
    uploaded: list = []
    for label, path in tracks:
        display_name = label
        print(f"uploading {path.name} ({path.stat().st_size/1e6:.1f} MB)...", flush=True)
        f = client.files.upload(file=str(path), config={"display_name": display_name})
        f = wait_active(client, f)
        uploaded.append(f)

    transcript_prompt = build_transcript_prompt(
        mic_exists, system_exists, segment_offset_seconds
    )

    response = generate_with_gemini(
        client,
        "[1/2] transcribing",
        contents=[transcript_prompt] + uploaded,
        config=types.GenerateContentConfig(
            temperature=0.2,
            max_output_tokens=65536,
        ),
    )
    check_finish_reason(response, "transcript")
    text = response.text or ""

    if "---TRANSCRIPT---" in text:
        _, transcript = text.split("---TRANSCRIPT---", 1)
        transcript = transcript.strip()
    else:
        transcript = text.strip()
        print("warning: missing ---TRANSCRIPT--- separator in call 1", flush=True)

    if finish_reason_name(response) == "MAX_TOKENS" and segment_offset_seconds is None:
        print(
            "warning: Gemini one-shot transcript hit max tokens; "
            "rerun with chunking for a complete transcript",
            flush=True,
        )

    return transcript, uploaded


def transcribe_with_gemini(
    client: genai.Client,
    tracks: list[tuple[str, Path]],
    mic_exists: bool,
    system_exists: bool,
) -> tuple[str, list]:
    if not should_chunk_gemini(tracks):
        return transcribe_with_gemini_once(client, tracks, mic_exists, system_exists)

    duration = max(audio_duration_seconds(path) or 0 for _, path in tracks)
    chunk_count = int((duration + GEMINI_CHUNK_SECONDS - 1) // GEMINI_CHUNK_SECONDS)
    print(
        f"[1/2] Gemini chunked transcription: {chunk_count} chunks of "
        f"{GEMINI_CHUNK_SECONDS}s...",
        flush=True,
    )
    transcript_parts: list[str] = []

    with tempfile.TemporaryDirectory(prefix="meetgist-gemini-") as tmp:
        chunks = split_audio_for_gemini(tracks, Path(tmp))
        for index, (offset, chunk_tracks) in enumerate(chunks, start=1):
            print(
                f"transcribing chunk {index}/{len(chunks)} "
                f"starting at {format_timestamp(offset)}...",
                flush=True,
            )
            transcript, uploaded = transcribe_with_gemini_once(
                client,
                chunk_tracks,
                mic_exists,
                system_exists,
                segment_offset_seconds=offset,
            )
            transcript_parts.append(offset_transcript_timestamps(transcript, offset))
            for f in uploaded:
                try:
                    client.files.delete(name=f.name)
                except Exception:
                    pass

    return "\n".join(part for part in transcript_parts if part.strip()), []


def split_audio_for_openai(path: Path, work_dir: Path) -> list[Path]:
    duration = audio_duration_seconds(path)
    max_bytes = OPENAI_MAX_UPLOAD_MB * 1_000_000
    if path.stat().st_size <= max_bytes and (
        duration is None or duration <= OPENAI_CHUNK_SECONDS
    ):
        return [path]

    output_dir = work_dir / path.stem
    output_dir.mkdir(parents=True, exist_ok=True)
    output_pattern = output_dir / "chunk-%04d.m4a"
    duration_desc = "unknown duration" if duration is None else f"{duration / 60:.1f} min"
    print(
        f"splitting {path.name} ({path.stat().st_size / 1e6:.1f} MB, {duration_desc}) "
        f"into {OPENAI_CHUNK_SECONDS}s OpenAI chunks...",
        flush=True,
    )
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-vn",
            "-map",
            "0:a:0",
            "-f",
            "segment",
            "-segment_time",
            str(OPENAI_CHUNK_SECONDS),
            "-reset_timestamps",
            "1",
            "-c:a",
            "aac",
            "-b:a",
            OPENAI_CHUNK_BITRATE,
            "-ac",
            "1",
            "-ar",
            "16000",
            str(output_pattern),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg split failed for {path}: {result.stderr.strip()}")

    chunks = sorted(output_dir.glob("chunk-*.m4a"))
    if not chunks:
        raise SystemExit(f"ffmpeg produced no chunks for {path}")

    oversize = [chunk.name for chunk in chunks if chunk.stat().st_size > max_bytes]
    if oversize:
        raise SystemExit(
            f"OpenAI chunks still exceed {OPENAI_MAX_UPLOAD_MB:g} MB: "
            f"{', '.join(oversize[:5])}"
        )
    return chunks


def transcribe_with_openai(
    tracks: list[tuple[str, Path]],
    mic_exists: bool,
    system_exists: bool,
) -> str:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise SystemExit(f"OPENAI_API_KEY not set; add it to {ENV_FILE}")

    try:
        from openai import OpenAI
    except ImportError as exc:
        raise SystemExit("openai package is not installed; run `make setup`") from exc

    client = OpenAI(api_key=api_key)
    diarize = OPENAI_TRANSCRIBE_MODEL == "gpt-4o-transcribe-diarize"
    lines: list[tuple[float, str]] = []
    speaker_maps: dict[str, dict[str, str]] = {"system": {}, "single": {}}

    print(f"[1/2] transcribing with OpenAI {OPENAI_TRANSCRIBE_MODEL}...", flush=True)
    with tempfile.TemporaryDirectory(prefix="meetgist-openai-") as tmp:
        work_dir = Path(tmp)
        for label, path in tracks:
            chunks = [path] if diarize else split_audio_for_openai(path, work_dir / label)
            offset = 0.0
            for chunk_index, chunk in enumerate(chunks, start=1):
                print(
                    f"uploading {path.name} chunk {chunk_index}/{len(chunks)} "
                    f"to OpenAI ({chunk.stat().st_size / 1e6:.1f} MB)...",
                    flush=True,
                )
                with chunk.open("rb") as audio_file:
                    result = transcribe_openai_chunk(client, audio_file, diarize)

                if not diarize:
                    text = result if isinstance(result, str) else field(result, "text", "")
                    text = str(text).strip()
                    if text:
                        speaker = speaker_label(label, mic_exists, system_exists)
                        lines.append(
                            (offset, f"[{format_timestamp(offset)}] {speaker}: {text}")
                        )
                    offset += audio_duration_seconds(chunk) or OPENAI_CHUNK_SECONDS
                    continue

                segments = field(result, "segments", []) or []
                if not segments:
                    text = str(field(result, "text", "")).strip()
                    if text:
                        speaker = speaker_label(label, mic_exists, system_exists)
                        lines.append((0, f"[00:00] {speaker}: {text}"))
                    continue

                for segment in segments:
                    text = str(field(segment, "text", "")).strip()
                    if not text:
                        continue

                    start = float(field(segment, "start", 0) or 0)
                    raw_speaker = str(field(segment, "speaker", "speaker")).strip() or "speaker"
                    if label == "mic":
                        speaker = "Me"
                    elif mic_exists and system_exists:
                        speaker_map = speaker_maps["system"]
                        speaker = speaker_map.setdefault(
                            raw_speaker, f"Participant {len(speaker_map) + 1}"
                        )
                    else:
                        speaker_map = speaker_maps["single"]
                        speaker = speaker_map.setdefault(
                            raw_speaker, f"Speaker {len(speaker_map) + 1}"
                        )

                    lines.append((start, f"[{format_timestamp(start)}] {speaker}: {text}"))

    lines.sort(key=lambda item: item[0])
    return "\n".join(line for _, line in lines)


def transcribe_openai_chunk(client, audio_file, diarize: bool):
    errors: list[str] = []
    for model in candidate_models(
        OPENAI_TRANSCRIBE_MODEL, OPENAI_TRANSCRIBE_FALLBACK_MODEL
    ):
        audio_file.seek(0)
        kwargs = {
            "model": model,
            "file": audio_file,
            "response_format": "diarized_json" if diarize else "text",
        }
        if diarize:
            kwargs["chunking_strategy"] = "auto"
        elif OPENAI_TRANSCRIBE_PROMPT and model != "whisper-1":
            kwargs["prompt"] = OPENAI_TRANSCRIBE_PROMPT

        try:
            response = client.audio.transcriptions.create(**kwargs)
            if model not in OPENAI_MODELS_USED:
                OPENAI_MODELS_USED.append(model)
            return response
        except Exception as exc:
            errors.append(f"{model}: {exc}")
            print(f"warning: OpenAI transcription model {model} failed: {exc}", flush=True)

    raise SystemExit("all OpenAI transcription models failed:\n" + "\n".join(errors))


def main(session_dir: str) -> None:
    session = Path(session_dir).expanduser().resolve()
    mic = session / "mic.m4a"
    system = session / "system.m4a"

    mic_exists = mic.exists()
    system_exists = system.exists()

    if not mic_exists and not system_exists:
        raise SystemExit(f"no audio files found in {session} — need mic.m4a and/or system.m4a")

    for _tool in ("ffmpeg", "ffprobe"):
        if shutil.which(_tool) is None:
            raise SystemExit(
                f"{_tool} not on PATH (PATH={os.environ.get('PATH', '')}). "
                "Install with `brew install ffmpeg`, or run via scripts/transcribe_meeting.sh."
            )

    load_dotenv(ENV_FILE)
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise SystemExit(f"GEMINI_API_KEY not set; see {ENV_FILE}")

    client = genai.Client(api_key=api_key)

    # ---- Dual-file sync (Phase 1-2): write sync_map.json + sync_report.md ----
    # Best-effort and additive; a sync failure must never block transcription.
    sync_confidence = None
    try:
        import sync_tracks
        sync_map = sync_tracks.generate(session)
        sync_confidence = sync_map.get("confidence")
        print(f"  sync: confidence={sync_confidence}", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"warning: sync stage skipped: {exc}", flush=True)

    # ---- Call 1: Audio -> Transcript ----
    tracks: list[tuple[str, Path]] = []
    if mic_exists:
        tracks.append(("mic", mic))

    if system_exists:
        tracks.append(("system", system))
    tracks = filter_low_signal_tracks(tracks)

    uploaded: list = []
    openai_error: str | None = None
    if use_openai_transcriber(tracks):
        try:
            transcript_backend = "openai"
            transcript = transcribe_with_openai(tracks, mic_exists, system_exists)
        except SystemExit as exc:
            if TRANSCRIPT_PROVIDER == "openai":
                raise
            openai_error = str(exc)
            print(
                "warning: OpenAI transcription failed in auto mode; "
                "falling back to Gemini chunked transcription",
                flush=True,
            )
            transcript_backend = "gemini"
            transcript, uploaded = transcribe_with_gemini(
                client, tracks, mic_exists, system_exists
            )
    else:
        transcript_backend = "gemini"
        transcript, uploaded = transcribe_with_gemini(
            client, tracks, mic_exists, system_exists
        )

    (session / "transcript.md").write_text(transcript + "\n")
    print(f"  transcript: {len(transcript)} chars, ~{len(transcript.split())} words", flush=True)

    # ---- Call 2: Transcript text -> Polished + Summary ----
    response2 = generate_with_gemini(
        client,
        "[2/2] polishing + summarizing",
        contents=[POLISHED_PROMPT, transcript],
        config=types.GenerateContentConfig(
            temperature=0.2,
            max_output_tokens=32768,
        ),
    )
    check_finish_reason(response2, "polished+summary")
    text2 = response2.text or ""

    if "---POLISHED---" in text2 and "---SUMMARY---" in text2:
        _, rest = text2.split("---POLISHED---", 1)
        polished, summary = rest.split("---SUMMARY---", 1)
        (session / "polished.md").write_text(polished.strip() + "\n")
        (session / "summary.md").write_text(summary.strip() + "\n")
        print(f"  polished: {len(polished)} chars, summary: {len(summary)} chars", flush=True)
    else:
        (session / "raw_output.md").write_text(text2)
        print("warning: missing separators in call 2; raw output saved to raw_output.md", flush=True)

    print(f"wrote transcript.md, polished.md, summary.md in {session}")
    (session / "postprocess_meta.json").write_text(
        json.dumps(
            {
                "transcript_backend": transcript_backend,
                "sync_confidence": sync_confidence,
                "sync_map": "sync_map.json" if sync_confidence else None,
                "gemini_models_used": GEMINI_MODELS_USED,
                "openai_models_used": OPENAI_MODELS_USED,
                "config": {
                    "gemini_model": GEMINI_MODEL,
                    "gemini_fallback_model": GEMINI_FALLBACK_MODEL,
                    "transcript_provider": TRANSCRIPT_PROVIDER,
                    "openai_transcribe_model": OPENAI_TRANSCRIBE_MODEL,
                    "openai_transcribe_fallback_model": OPENAI_TRANSCRIBE_FALLBACK_MODEL,
                    "gemini_audio_request_max_mb": GEMINI_AUDIO_REQUEST_MAX_MB,
                    "openai_file_threshold_ratio": OPENAI_FILE_THRESHOLD_RATIO,
                    "openai_file_threshold_mb": GEMINI_AUDIO_REQUEST_MAX_MB
                    * OPENAI_FILE_THRESHOLD_RATIO,
                    "openai_chunk_seconds": OPENAI_CHUNK_SECONDS,
                    "openai_min_mean_volume_db": OPENAI_MIN_MEAN_VOLUME_DB,
                    "gemini_chunk_seconds": GEMINI_CHUNK_SECONDS,
                    "gemini_chunk_min_duration_seconds": (
                        GEMINI_CHUNK_MIN_DURATION_SECONDS
                    ),
                },
                "openai_error": openai_error,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )

    # Clean up uploaded files from Gemini (they auto-expire in 48h anyway).
    for f in uploaded:
        try:
            client.files.delete(name=f.name)
        except Exception:
            pass

    notify(f"Meeting notes ready: {session.name}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: postprocess.py <session_dir>")
    main(sys.argv[1])
