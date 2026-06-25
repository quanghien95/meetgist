#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
set -euo pipefail

# Shortcuts.app "Run Shell Script" hands us a minimal PATH that excludes
# Homebrew, so the bare `ffmpeg`/`ffprobe` calls inside postprocess.py fail
# with FileNotFoundError. Make the Homebrew bins discoverable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
POSTPROCESS="$SCRIPT_DIR/postprocess.py"
TRANSCRIBE_FILE="$SCRIPT_DIR/transcribe_file.py"

# Run logs go to a LOCAL dir, never into the Dropbox session folder.
# A Finder Quick Action runs under a TCC context that can create new files in
# the dropped folder but CANNOT overwrite an existing Dropbox-synced file
# (e.g. a prior postprocess.log carries com.dropbox.* xattrs -> EPERM on
# truncate). Transcription itself succeeds; only that log overwrite failed,
# and its stderr was the "error" surfaced by the Quick Action. Logging locally
# removes it entirely and keeps a per-run log for debugging.
LOG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/logs"
mkdir -p "$LOG_DIR"

process_one() {
  local target="$1"
  local log="$LOG_DIR/$(basename "$target")-$(date '+%Y%m%d-%H%M%S').log"
  {
    echo "# meetgist run $(date '+%Y-%m-%d %H:%M:%S')  argv=$target"
    echo "# PATH=$PATH"
  } > "$log"

  if [[ -d "$target" ]]; then
    # A meetgist session folder (mic.m4a / system.m4a) → transcribe in place.
    if [[ -f "$target/mic.m4a" || -f "$target/system.m4a" ]]; then
      "$PYTHON" "$POSTPROCESS" "$target" 2>&1 | tee -a "$log"
      return "${PIPESTATUS[0]}"
    fi
    # Otherwise treat it as a folder of imported recordings (e.g. a single
    # xxx.mp3 copied in by hand): transcribe each audio file into a new session
    # folder. transcribe_file.py decides speaker splitting from content, so a
    # one-voice memo stays single-speaker and a conversation is split into
    # Speaker 1 / Speaker 2 / … automatically.
    "$PYTHON" "$TRANSCRIBE_FILE" "$target" 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
  fi

  if [[ -f "$target" ]]; then
    "$PYTHON" "$TRANSCRIBE_FILE" "$target" 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
  fi

  echo "not found: $target" >&2
  return 1
}

if [[ $# -eq 0 ]]; then
  echo "usage: transcribe_meeting.sh <audio-file-or-meeting-folder> [more ...]" >&2
  echo "  - audio file (.m4a/.mp3/.wav/.mp4)        -> transcribed into a new session folder" >&2
  echo "  - meeting folder (mic.m4a and/or system.m4a) -> transcribed in place" >&2
  echo "  - folder of imported audio (e.g. one xxx.mp3) -> each file -> a new session folder" >&2
  exit 64
fi

status=0
for target in "$@"; do
  process_one "$target" || status=$?
done
exit "$status"
