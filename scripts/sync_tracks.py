#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Phase 1-2 dual-file sync for meetgist (see dual-file-sync-engineering-plan.md).

Reads `capture_timing.json` from a session folder, probes `system.m4a` /
`mic.m4a` durations, and writes `sync_map.json` + `sync_report.md`. The sync map
is an affine transform per track into the session master timeline (system audio):

    master_time = offset_seconds + scale * local_track_time

v1 produces "coarse" confidence: the mic offset comes from the AVAudioRecorder
start-call anchors and the scale from the duration ratio. Phases 4-5 of the plan
raise confidence to "buffer"/"verified". Missing/partial metadata yields
confidence "none" with warnings — never a crash.

Usage: sync_tracks.py <session_dir>
"""
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = 1
NS_PER_SEC = 1_000_000_000


# --------------------------------------------------------------------------
# Pure logic (unit-tested without audio files or third-party deps)
# --------------------------------------------------------------------------

def affine_map(offset_seconds: float, scale: float, local_seconds: float) -> float:
    """Map a local-track timestamp into the master timeline."""
    return offset_seconds + scale * local_seconds


def build_sync_map(timing: dict | None,
                   system_duration: float | None,
                   mic_duration: float | None) -> dict:
    """Compute the sync map from capture timing + probed durations. Pure, no IO.

    System audio is the master timeline (offset 0, scale 1). The mic is mapped:
      - offset = master time at mic local t=0 = (mic_started - sys_first_buffer)
      - scale  = system_duration / mic_duration   (clock-drift ratio)
    """
    warnings: list[str] = []
    system = (timing or {}).get("system") or {}
    mic = (timing or {}).get("mic") or {}

    sys_first = system.get("first_buffer_host_ns") or 0
    mic_started = mic.get("record_started_host_ns") or 0

    if sys_first and mic_started:
        offset_mic = (mic_started - sys_first) / NS_PER_SEC
    else:
        offset_mic = 0.0
        warnings.append("missing host-time anchors; mic offset assumed 0.0")

    if system_duration and mic_duration and mic_duration > 0:
        scale_mic = system_duration / mic_duration
    else:
        scale_mic = 1.0
        warnings.append("missing track durations; mic scale assumed 1.0")

    if not timing or not sys_first:
        confidence = "none"
    elif mic_started:
        confidence = "coarse"
    else:
        confidence = "none"

    if abs(offset_mic) > 2.0:
        warnings.append(f"large mic offset {offset_mic:.3f}s (>2s) — verify capture")
    if abs(scale_mic - 1.0) > 0.05:
        warnings.append(f"mic scale {scale_mic:.5f} drifts >5% from 1.0 — suspect durations")

    return {
        "schema_version": SCHEMA_VERSION,
        "master": "system",
        "system": {"file": "system.m4a", "offset_seconds": 0.0, "scale": 1.0},
        "mic": {
            "file": "mic.m4a",
            "offset_seconds": round(offset_mic, 6),
            "scale": round(scale_mic, 8),
        },
        "confidence": confidence,
        "warnings": warnings,
    }


# --------------------------------------------------------------------------
# IO
# --------------------------------------------------------------------------

def audio_duration_seconds(path: Path) -> float | None:
    """Probe duration via afinfo (macOS) then ffprobe. None if unavailable."""
    p = str(path)
    try:
        r = subprocess.run(["afinfo", p], capture_output=True, text=True, check=False)
        if r.returncode == 0:
            m = re.search(r"estimated duration:\s+([0-9.]+)\s+sec", r.stdout)
            if m:
                return float(m.group(1))
    except FileNotFoundError:
        pass
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", p],
            capture_output=True, text=True, check=False)
        if r.returncode == 0 and r.stdout.strip():
            return float(r.stdout.strip())
    except (FileNotFoundError, ValueError):
        pass
    return None


def _fmt(x) -> str:
    return "n/a" if x is None else f"{x:.3f}"


def render_report(session: Path, timing: dict | None, sync_map: dict,
                  sys_dur: float | None, mic_dur: float | None) -> str:
    mic = sync_map["mic"]
    lines = [
        f"# Sync report — {session.name}",
        "",
        f"- **Confidence:** `{sync_map['confidence']}`",
        f"- **Master timeline:** system.m4a",
        f"- **system duration:** {_fmt(sys_dur)} s",
        f"- **mic duration:** {_fmt(mic_dur)} s",
        f"- **mic offset:** {mic['offset_seconds']:.6f} s "
        "(master time at mic local t=0; positive = mic started later)",
        f"- **mic scale:** {mic['scale']:.8f} (system/mic duration ratio; clock drift)",
        "",
        "Mapping: `master_time = offset + scale × local_track_time`",
        "",
    ]
    if sync_map["warnings"]:
        lines.append("## Warnings")
        lines += [f"- {w}" for w in sync_map["warnings"]]
        lines.append("")
    if not timing:
        lines.append("> No `capture_timing.json` found — offsets are best-effort.")
        lines.append("")
    lines.append("_Generated by sync_tracks.py (dual-file sync Phase 1-2)._")
    return "\n".join(lines) + "\n"


def generate(session_dir) -> dict:
    """Read capture_timing.json, probe durations, write sync_map.json +
    sync_report.md. Returns the sync map. Never raises on missing metadata."""
    session = Path(session_dir)
    timing = None
    timing_path = session / "capture_timing.json"
    if timing_path.exists():
        try:
            timing = json.loads(timing_path.read_text())
        except Exception:
            timing = None

    sys_path = session / "system.m4a"
    mic_path = session / "mic.m4a"
    sys_dur = audio_duration_seconds(sys_path) if sys_path.exists() else None
    mic_dur = audio_duration_seconds(mic_path) if mic_path.exists() else None

    sync_map = build_sync_map(timing, sys_dur, mic_dur)
    (session / "sync_map.json").write_text(
        json.dumps(sync_map, ensure_ascii=False, indent=2) + "\n")
    (session / "sync_report.md").write_text(
        render_report(session, timing, sync_map, sys_dur, mic_dur))
    return sync_map


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: sync_tracks.py <session_dir>")
    m = generate(sys.argv[1])
    print(
        f"sync: confidence={m['confidence']} "
        f"mic.offset={m['mic']['offset_seconds']}s mic.scale={m['mic']['scale']}",
        flush=True,
    )
    for w in m["warnings"]:
        print(f"  warning: {w}", flush=True)


if __name__ == "__main__":
    main()
