#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Transcribe pre-recorded audio files through the meetgist pipeline.

Output is written **in place**: the generated documents land next to the source
file, in the same folder, named after it — `<name>.transcript.md`,
`<name>.polished.md` and `<name>.summary.md`. The original audio is never
modified, and nothing is copied into the meetgist output folder.

Transcription runs in a throwaway staging folder (the audio is copied in as
`mic.m4a`/`system.m4a` so postprocess.py can consume it); the resulting markdown
is then moved beside the source and the staging folder is discarded.

Usage:
    transcribe_file.py <audio_path> [<audio_path> ...] [--title NAME] [--source mic|system|auto]
    transcribe_file.py <folder>     # transcribe every audio file directly inside a folder

Supported formats: .m4a, .mp3, .wav, .mp4
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
POSTPROCESS = HERE / "postprocess.py"
VENV_PYTHON = HERE / ".venv" / "bin" / "python3"

VALID_EXTENSIONS = {".m4a", ".mp3", ".wav", ".mp4"}

# postprocess.py writes these into the session dir; we move whichever exist next
# to the source file, stem-prefixed. raw_output.md only appears on a fallback.
OUTPUT_DOCS = ("transcript.md", "polished.md", "summary.md", "raw_output.md")


def safe_prefix(name: str) -> str:
    """A filename-safe prefix for the in-place output docs."""
    cleaned = "".join(
        c if c.isalnum() or c in " -_." else "-" for c in name
    ).strip(" .-")
    return cleaned or "transcript"


def place_outputs(staging: Path, dest_dir: Path, prefix: str) -> list[str]:
    """Move the generated docs from the staging folder next to the source."""
    written: list[str] = []
    for name in OUTPUT_DOCS:
        produced = staging / name
        if not produced.exists():
            continue
        dest = dest_dir / f"{prefix}.{name}"
        if dest.exists():  # re-transcription overwrites the prior docs
            dest.unlink()
        shutil.move(str(produced), str(dest))
        written.append(dest.name)
    return written


def transcribe_one(src: Path, title: str | None, source: str) -> bool:
    if src.suffix.lower() not in VALID_EXTENSIONS:
        print(
            f"  skipping {src.name}: unsupported format "
            f"({', '.join(sorted(VALID_EXTENSIONS))} only)",
            flush=True,
        )
        return False

    target_name = "mic.m4a" if source == "mic" else "system.m4a"
    prefix = safe_prefix(title or src.stem)
    dest_dir = src.parent
    python = str(VENV_PYTHON) if VENV_PYTHON.exists() else sys.executable

    print(
        f"processing {src} ({src.stat().st_size / 1e6:.1f} MB) → {dest_dir}",
        flush=True,
    )

    with tempfile.TemporaryDirectory(prefix="meetgist-import-") as tmp:
        # Name the staging folder after the source so postprocess's "notes
        # ready" notification reads naturally.
        staging = Path(tmp) / src.stem
        staging.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, staging / target_name)

        result = subprocess.run([python, str(POSTPROCESS), str(staging)])
        if result.returncode != 0:
            print("  failed", flush=True)
            return False

        moved = place_outputs(staging, dest_dir, prefix)

    if moved:
        print(f"  output → {dest_dir}: {', '.join(moved)}", flush=True)
        return True
    print("  no transcript produced", flush=True)
    return False


def collect_inputs(paths: list[str]) -> list[Path]:
    """Expand the given paths into a flat list of audio files.

    A directory expands to the audio files directly inside it (non-recursive),
    which replaces the old inbox/ batch workflow: point at any folder of
    recordings instead of dropping them into a magic directory.
    """
    inputs: list[Path] = []
    for raw in paths:
        p = Path(raw).expanduser()
        if not p.exists():
            raise SystemExit(f"not found: {p}")
        if p.is_dir():
            audio = sorted(
                f for f in p.iterdir()
                if f.is_file() and f.suffix.lower() in VALID_EXTENSIONS
            )
            if not audio:
                print(f"warning: no audio files in {p}", flush=True)
            inputs.extend(audio)
        else:
            inputs.append(p.resolve())
    return inputs


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcribe pre-recorded audio files via meetgist (output written in place)."
    )
    parser.add_argument(
        "audio_paths",
        nargs="+",
        help="one or more audio files, or a folder of audio files",
    )
    parser.add_argument(
        "--title", "-t", default=None,
        help="output filename prefix (single file only; defaults to the source name)",
    )
    parser.add_argument(
        "--source",
        choices=["mic", "system", "auto"],
        default="auto",
        help="which track slot (default: auto → system)",
    )
    args = parser.parse_args()

    inputs = collect_inputs(args.audio_paths)
    if not inputs:
        raise SystemExit("no audio files to transcribe")

    # --title only makes sense for a single input; otherwise use each file stem.
    title = args.title if len(inputs) == 1 else None

    print(f"transcribing {len(inputs)} file(s) in place\n", flush=True)
    ok = 0
    for f in inputs:
        try:
            if transcribe_one(f, title, args.source):
                ok += 1
        except Exception as e:  # noqa: BLE001 - keep batch going
            print(f"  error: {e}", flush=True)
        print()

    print(f"done: {ok}/{len(inputs)} succeeded")
    if ok < len(inputs):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
