#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
"""Pure unit tests for the dual-file sync logic (no audio / no deps).

Run standalone:  python3 tests/test_sync_tracks.py
Or with unittest discovery: python3 -m unittest discover -s tests -p 'test_*.py'
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import sync_tracks  # noqa: E402

TOL = 1e-9


def _anchors(sys_first_ns, mic_started_ns):
    return {
        "system": {"first_buffer_host_ns": sys_first_ns},
        "mic": {"record_started_host_ns": mic_started_ns},
    }


class SyncTracksTests(unittest.TestCase):
    def test_affine_map_exact(self):
        # master = offset + scale * local
        self.assertLess(abs(sync_tracks.affine_map(0.25, 0.9999, 100.0) - (0.25 + 0.9999 * 100.0)), TOL)
        self.assertLess(abs(sync_tracks.affine_map(0.0, 1.0, 42.0) - 42.0), TOL)

    def test_affine_map_monotonic(self):
        # With positive scale, ordering is preserved (basis for monotonic transcripts).
        f = lambda t: sync_tracks.affine_map(0.5, 1.0001, t)
        xs = [0.0, 1.5, 1.5, 9.9, 100.0]
        ys = [f(t) for t in xs]
        self.assertEqual(ys, sorted(ys))

    def test_missing_metadata_is_none_confidence(self):
        m = sync_tracks.build_sync_map(None, None, None)
        self.assertEqual(m["confidence"], "none")
        self.assertTrue(m["warnings"])  # must warn, not crash
        self.assertEqual(m["mic"]["offset_seconds"], 0.0)
        self.assertEqual(m["mic"]["scale"], 1.0)
        self.assertEqual(m["system"], {"file": "system.m4a", "offset_seconds": 0.0, "scale": 1.0})

    def test_offset_from_anchors(self):
        # mic started 62 ms after the system's first buffer
        timing = _anchors(1_000_000_000, 1_062_000_000)
        m = sync_tracks.build_sync_map(timing, 600.0, 600.0)
        self.assertLess(abs(m["mic"]["offset_seconds"] - 0.062), 1e-6)
        self.assertEqual(m["confidence"], "coarse")

    def test_duration_mismatch_sets_scale(self):
        # doc test case 4: system 7200.0s, mic 7200.5s -> scale ~ 7200.0/7200.5
        timing = _anchors(1_000_000_000, 1_000_000_000)
        m = sync_tracks.build_sync_map(timing, 7200.0, 7200.5)
        self.assertLess(abs(m["mic"]["scale"] - (7200.0 / 7200.5)), 1e-6)
        # 0.007% drift -> no drift warning
        self.assertFalse(any("drifts" in w for w in m["warnings"]))

    def test_large_drift_warns(self):
        timing = _anchors(1_000_000_000, 1_000_000_000)
        m = sync_tracks.build_sync_map(timing, 100.0, 90.0)  # 11% off
        self.assertTrue(any("drift" in w for w in m["warnings"]))

    def test_large_offset_warns(self):
        timing = _anchors(1_000_000_000, 4_000_000_000)  # 3s late
        m = sync_tracks.build_sync_map(timing, 600.0, 600.0)
        self.assertTrue(any("offset" in w for w in m["warnings"]))


if __name__ == "__main__":
    unittest.main()
