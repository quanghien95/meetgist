#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Pure unit tests for the dual-file sync logic (no audio / no deps).

Run standalone:  python3 tests/test_sync_tracks.py
Or with pytest:  pytest tests/test_sync_tracks.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import sync_tracks  # noqa: E402

TOL = 1e-9


def _anchors(sys_first_ns, mic_started_ns):
    return {
        "system": {"first_buffer_host_ns": sys_first_ns},
        "mic": {"record_started_host_ns": mic_started_ns},
    }


def test_affine_map_exact():
    # master = offset + scale * local
    assert abs(sync_tracks.affine_map(0.25, 0.9999, 100.0) - (0.25 + 0.9999 * 100.0)) < TOL
    assert abs(sync_tracks.affine_map(0.0, 1.0, 42.0) - 42.0) < TOL


def test_affine_map_monotonic():
    # With positive scale, ordering is preserved (basis for monotonic transcripts).
    f = lambda t: sync_tracks.affine_map(0.5, 1.0001, t)
    xs = [0.0, 1.5, 1.5, 9.9, 100.0]
    ys = [f(t) for t in xs]
    assert ys == sorted(ys)


def test_missing_metadata_is_none_confidence():
    m = sync_tracks.build_sync_map(None, None, None)
    assert m["confidence"] == "none"
    assert m["warnings"]                      # must warn, not crash
    assert m["mic"]["offset_seconds"] == 0.0
    assert m["mic"]["scale"] == 1.0
    assert m["system"] == {"file": "system.m4a", "offset_seconds": 0.0, "scale": 1.0}


def test_offset_from_anchors():
    # mic started 62 ms after the system's first buffer
    timing = _anchors(1_000_000_000, 1_062_000_000)
    m = sync_tracks.build_sync_map(timing, 600.0, 600.0)
    assert abs(m["mic"]["offset_seconds"] - 0.062) < 1e-6
    assert m["confidence"] == "coarse"


def test_duration_mismatch_sets_scale():
    # doc test case 4: system 7200.0s, mic 7200.5s -> scale ~ 7200.0/7200.5
    timing = _anchors(1_000_000_000, 1_000_000_000)
    m = sync_tracks.build_sync_map(timing, 7200.0, 7200.5)
    assert abs(m["mic"]["scale"] - (7200.0 / 7200.5)) < 1e-6
    # 0.007% drift -> no drift warning
    assert not any("drifts" in w for w in m["warnings"])


def test_large_drift_warns():
    timing = _anchors(1_000_000_000, 1_000_000_000)
    m = sync_tracks.build_sync_map(timing, 100.0, 90.0)  # 11% off
    assert any("drift" in w for w in m["warnings"])


def test_large_offset_warns():
    timing = _anchors(1_000_000_000, 4_000_000_000)  # 3s late
    m = sync_tracks.build_sync_map(timing, 600.0, 600.0)
    assert any("offset" in w for w in m["warnings"])


def _run():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  ok   {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(_run())
