#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Rasterize the master icon (icon.png) into the macOS AppIcon.appiconset via sips.
#   scripts/make-icon.sh [path-to-master.png]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/icon.png}"
OUT="$ROOT/app/Resources/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "master icon not found: $SRC" >&2; exit 1; }
mkdir -p "$OUT"

gen() { sips -s format png -z "$2" "$2" "$SRC" --out "$OUT/$1" >/dev/null; }
gen icon_16x16.png      16
gen icon_16x16@2x.png   32
gen icon_32x32.png      32
gen icon_32x32@2x.png   64
gen icon_128x128.png    128
gen icon_128x128@2x.png 256
gen icon_256x256.png    256
gen icon_256x256@2x.png 512
gen icon_512x512.png    512
gen icon_512x512@2x.png 1024

echo "wrote AppIcon.appiconset from $SRC"
