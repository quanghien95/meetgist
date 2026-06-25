#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Auto-import new Apple Voice Memos and transcribe them, hands-free.

Voice memos recorded on an iPhone, Apple Watch or Mac all sync into the local
Voice Memos store. This scans that store for *new* recordings (ones not seen
before), copies each into a sensibly-named session folder under
MEETGIST_OUTPUT_DIR, and runs postprocess.py to write transcript.md / polished.md
/ summary.md there — the same layout as a recorded meeting. A small JSON ledger
remembers what's been handled so nothing is transcribed twice.

Designed to be run on a timer by a launchd agent (see
install_voicememo_watcher.sh), but also works by hand.

Modes:
    import_voicememos.py            # transcribe any new memos (default)
    import_voicememos.py --seed     # mark all current memos as seen, transcribe none
    import_voicememos.py --dry-run  # show what would happen, change nothing
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

HERE = Path(__file__).resolve().parent
load_dotenv(HERE / ".env")

POSTPROCESS = HERE / "postprocess.py"
VENV_PYTHON = HERE / ".venv" / "bin" / "python3"

VOICEMEMOS_DIR = Path(
    os.path.expanduser(
        os.getenv("VOICEMEMOS_DIR")
        or "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    )
)
OUTPUT_DIR = Path(
    os.path.expanduser(
        os.getenv("MEETGIST_OUTPUT_DIR") or str(Path.home() / "Documents" / "meetgist")
    )
)
LEDGER = Path(
    os.path.expanduser(
        os.getenv("MEETGIST_MEMO_LEDGER")
        or "~/Library/Caches/meetgist/imported-voicememos.json"
    )
)

# A memo must be at least this big and this old (untouched) before we touch it,
# so we never grab a file that iCloud is still syncing or that's mid-write.
MIN_BYTES = int(os.getenv("MEETGIST_MEMO_MIN_BYTES", "16384"))
SETTLE_SECONDS = int(os.getenv("MEETGIST_MEMO_SETTLE_SECONDS", "90"))
# Cap per run so a big sync can't kick off dozens of transcriptions at once.
MAX_PER_RUN = int(os.getenv("MEETGIST_MEMO_MAX_PER_RUN", "10"))
MAX_ATTEMPTS = 3


def log(msg: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


def notify(message: str) -> None:
    safe = message.replace('"', "'")
    os.system(
        f'osascript -e \'display notification "{safe}" with title "meetgist"\' 2>/dev/null'
    )


def load_ledger() -> dict:
    try:
        return json.loads(LEDGER.read_text())
    except Exception:
        return {}


def save_ledger(ledger: dict) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    tmp = LEDGER.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(ledger, ensure_ascii=False, indent=2))
    tmp.replace(LEDGER)


def list_memos() -> list[Path]:
    if not VOICEMEMOS_DIR.is_dir():
        return []
    return sorted(
        f for f in VOICEMEMOS_DIR.iterdir()
        if f.is_file() and f.suffix.lower() == ".m4a"
    )


def is_ready(path: Path) -> bool:
    try:
        st = path.stat()
    except OSError:
        return False
    if st.st_size < MIN_BYTES:
        return False  # iCloud placeholder or empty
    return (time.time() - st.st_mtime) >= SETTLE_SECONDS


def memo_title(filename: str) -> str | None:
    db = VOICEMEMOS_DIR / "CloudRecordings.db"
    if not db.exists():
        return None
    try:
        con = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
        try:
            row = con.execute(
                "SELECT ZCUSTOMLABEL FROM ZCLOUDRECORDING "
                "WHERE ZPATH = ? OR ZPATH LIKE ? LIMIT 1",
                (filename, f"%{filename}"),
            ).fetchone()
        finally:
            con.close()
    except Exception:
        return None
    if row and row[0]:
        title = str(row[0]).strip()
        return title or None
    return None


def stamp_from_name(filename: str, fallback_mtime: float) -> str:
    m = re.match(r"(\d{4})(\d{2})(\d{2})[ _-](\d{2})(\d{2})", filename)
    if m:
        y, mo, d, h, mi = m.groups()
        return f"{y}-{mo}-{d}-{h}{mi}"
    return datetime.fromtimestamp(fallback_mtime).strftime("%Y-%m-%d-%H%M")


def safe_name(name: str) -> str:
    cleaned = "".join(
        c if c.isalnum() or c in " -_." else "-" for c in name
    ).strip(" .-")
    return cleaned[:80]


def session_dir_for(memo: Path) -> Path:
    stamp = stamp_from_name(memo.name, memo.stat().st_mtime)
    title = safe_name(memo_title(memo.name) or "")
    base = f"{stamp}-{title}" if title else f"{stamp}-voicememo"
    dest = OUTPUT_DIR / base
    if dest.exists():
        # Disambiguate with the memo's own unique hash suffix.
        suffix = memo.stem.split("-")[-1][:6] or "memo"
        dest = OUTPUT_DIR / f"{base}-{suffix}"
    return dest


def run_postprocess(session: Path) -> bool:
    python = str(VENV_PYTHON) if VENV_PYTHON.exists() else sys.executable
    # postprocess shells out to ffmpeg/ffprobe/afinfo; make Homebrew reachable
    # under launchd's minimal PATH.
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    result = subprocess.run([python, str(POSTPROCESS), str(session)], env=env)
    return result.returncode == 0


def transcribe_memo(memo: Path, ledger: dict, dry_run: bool) -> bool:
    dest = session_dir_for(memo)
    if dry_run:
        log(f"  would import {memo.name} -> {dest}")
        return True

    log(f"  importing {memo.name} -> {dest}")
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(memo, dest / "system.m4a")
    ok = run_postprocess(dest)
    entry = ledger.get(memo.name, {})
    if ok:
        ledger[memo.name] = {
            "status": "done",
            "session": str(dest),
            "ts": datetime.now().isoformat(timespec="seconds"),
        }
        log(f"  done -> {dest}")
        notify(f"Voice memo transcribed: {dest.name}")
    else:
        ledger[memo.name] = {
            "status": "failed",
            "attempts": int(entry.get("attempts", 0)) + 1,
            "session": str(dest),
            "ts": datetime.now().isoformat(timespec="seconds"),
        }
        log(f"  FAILED postprocess for {memo.name}")
    return ok


def needs_processing(name: str, ledger: dict) -> bool:
    entry = ledger.get(name)
    if entry is None:
        return True
    if entry.get("status") == "failed" and int(entry.get("attempts", 0)) < MAX_ATTEMPTS:
        return True
    return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Auto-import + transcribe new Voice Memos.")
    parser.add_argument(
        "--seed", action="store_true",
        help="mark all current memos as already seen (transcribe none) — run once at install",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="report what would be imported without copying or transcribing",
    )
    parser.add_argument(
        "--limit", type=int, default=MAX_PER_RUN,
        help=f"max memos to transcribe in one run (default {MAX_PER_RUN})",
    )
    args = parser.parse_args()

    if not VOICEMEMOS_DIR.is_dir():
        raise SystemExit(
            f"Voice Memos folder not found: {VOICEMEMOS_DIR}\n"
            "Set VOICEMEMOS_DIR in scripts/.env if your store lives elsewhere."
        )

    memos = list_memos()
    ledger = load_ledger()

    if args.seed:
        seeded = 0
        for memo in memos:
            if memo.name not in ledger:
                ledger[memo.name] = {
                    "status": "seeded",
                    "ts": datetime.now().isoformat(timespec="seconds"),
                }
                seeded += 1
        save_ledger(ledger)
        log(f"seeded {seeded} existing memo(s); only memos recorded from now on will import")
        return

    new = [m for m in memos if needs_processing(m.name, ledger)]
    if not new:
        log(f"no new voice memos ({len(memos)} total, all handled)")
        return

    ready = [m for m in new if is_ready(m)]
    waiting = len(new) - len(ready)
    log(
        f"{len(ready)} new memo(s) ready"
        + (f", {waiting} still syncing/settling" if waiting else "")
    )

    done = 0
    for memo in ready[: args.limit]:
        try:
            if transcribe_memo(memo, ledger, args.dry_run):
                done += 1
        except Exception as e:  # noqa: BLE001 - keep going, persist progress
            log(f"  error on {memo.name}: {e}")
        finally:
            if not args.dry_run:
                save_ledger(ledger)

    if len(ready) > args.limit:
        log(f"processed {args.limit}; {len(ready) - args.limit} more will run next poll")
    log(f"done: {done} memo(s) transcribed")


if __name__ == "__main__":
    main()
