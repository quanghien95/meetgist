#!/usr/bin/env python3
"""Re-run ONLY step 2 of meetgist's pipeline: transcript.md -> polished.md + summary.md.

Reuses postprocess.POLISHED_PROMPT verbatim so the output format is identical.
Never touches transcript.md / mic.m4a / system.m4a. Backs up the existing
polished.md + summary.md before overwriting. Uses GEMINI_MODEL only -- NO
fallback to the weaker flash-lite (falling back is what produced the generic
"Meeting Minutes" titles we are replacing).

usage: repolish.py <session_dir> [more ...]

Written 2026-07-29 to recover three sessions whose polished.md fell back to
gemini-3.1-flash-lite during a 3.5-flash outage. Idempotent: an existing backup is
never overwritten, so re-running after a failed attempt is safe.
"""
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

from dotenv import load_dotenv  # noqa: E402
from google import genai  # noqa: E402
from google.genai import types  # noqa: E402

import postprocess  # noqa: E402  (module-level import is safe; preflight lives in main())

load_dotenv(SCRIPTS / ".env")
MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
BACKUP_SUFFIX = os.getenv("REPOLISH_BACKUP_SUFFIX", "flash-lite.bak")


def first_h1(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return "(no H1 found)"


def generate_with_retry(client: genai.Client, transcript: str):
    """Retry the SAME model on transient 503/429/500. Never switches to a weaker model."""
    delay = float(os.getenv("REPOLISH_BACKOFF_START", "20"))
    attempts = int(os.getenv("REPOLISH_ATTEMPTS", "8"))
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return client.models.generate_content(
                model=MODEL,
                contents=[postprocess.POLISHED_PROMPT, transcript],
                config=types.GenerateContentConfig(temperature=0.2, max_output_tokens=32768),
            )
        except Exception as exc:  # noqa: BLE001
            code = getattr(exc, "code", None) or getattr(exc, "status_code", None)
            transient = code in (429, 500, 502, 503, 504) or "503" in str(exc)[:80]
            last = exc
            if not transient or attempt == attempts:
                raise
            print(
                f"    attempt {attempt}/{attempts} got {code or 'error'}; "
                f"retrying same model in {delay:.0f}s",
                flush=True,
            )
            time.sleep(delay)
            delay = min(delay * 1.7, 120)
    raise last  # pragma: no cover


def repolish(session: Path, client: genai.Client) -> None:
    transcript_path = session / "transcript.md"
    if not transcript_path.exists():
        raise SystemExit(f"no transcript.md in {session}")

    transcript = transcript_path.read_text()
    print(f"\n=== {session.name}")
    print(f"  transcript: {len(transcript)} chars")

    old_polished = session / "polished.md"
    old_summary = session / "summary.md"
    old_title = first_h1(old_polished.read_text()) if old_polished.exists() else "(none)"
    print(f"  OLD title: {old_title}")

    # ---- backup before anything can overwrite ----
    for src, name in ((old_polished, "polished"), (old_summary, "summary")):
        if src.exists():
            dst = session / f"{name}.{BACKUP_SUFFIX}.md"
            if dst.exists():
                print(f"  backup already exists, keeping: {dst.name}")
            else:
                shutil.copy2(src, dst)
                print(f"  backed up -> {dst.name}")

    print(f"  [2/2] polishing + summarizing with Gemini {MODEL} (no fallback)...", flush=True)
    response = generate_with_retry(client, transcript)
    postprocess.check_finish_reason(response, "polished+summary")
    text = response.text or ""

    if "---POLISHED---" not in text or "---SUMMARY---" not in text:
        (session / "raw_output.repolish.md").write_text(text)
        raise SystemExit(
            f"  ERROR: missing separators in response for {session.name}; "
            "raw output saved to raw_output.repolish.md; originals left untouched"
        )

    _, rest = text.split("---POLISHED---", 1)
    polished, summary = rest.split("---SUMMARY---", 1)
    polished, summary = polished.strip() + "\n", summary.strip() + "\n"

    old_polished.write_text(polished)
    old_summary.write_text(summary)
    print(f"  polished: {len(polished)} chars, summary: {len(summary)} chars")

    new_title = first_h1(polished)
    print(f"  NEW title: {new_title}")
    if new_title.strip().lower() in {"meeting minutes", "会议记录", '[meeting title or "meeting minutes"]'}:
        print("  !! STILL GENERIC -- title did not improve")

    # record what happened, without clobbering the transcription provenance
    meta_path = session / "postprocess_meta.json"
    try:
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        meta.setdefault("gemini_models_used", {})["[2/2] polishing + summarizing"] = MODEL
        meta["repolish"] = {
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "model": MODEL,
            "note": "step 2 only, re-run from existing transcript.md; no re-transcription",
            "backups": [f"polished.{BACKUP_SUFFIX}.md", f"summary.{BACKUP_SUFFIX}.md"],
        }
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    except Exception as exc:  # noqa: BLE001
        print(f"  warning: could not update postprocess_meta.json: {exc}")


def main(argv: list[str]) -> None:
    if not argv:
        raise SystemExit("usage: repolish.py <session_dir> [more ...]")
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise SystemExit(f"GEMINI_API_KEY not set; see {SCRIPTS / '.env'}")
    client = genai.Client(api_key=api_key)
    print(f"model = {MODEL} (fallback disabled)")
    for arg in argv:
        repolish(Path(arg).expanduser().resolve(), client)


if __name__ == "__main__":
    main(sys.argv[1:])
