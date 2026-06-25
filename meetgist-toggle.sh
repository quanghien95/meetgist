#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
# meetgist control script.
#   meetgist-toggle.sh          start recording (or stop + transcribe if running)
#   meetgist-toggle.sh status   show whether a recording is running + latest notes
#   meetgist-toggle.sh open     open the output folder in Finder
#   meetgist-toggle.sh last     open the most recent session folder in Finder
#
# Invoked from a macOS Shortcuts "Run Shell Script" action, from the shell
# aliases installed by setup.sh, or directly. Shortcuts runs us in a minimal
# context where $HOME/$USER may be unset and PATH excludes Homebrew, so we
# resolve everything from this script's own location and fall back carefully —
# nothing is hardcoded to one machine.

set -u

# --- Resolve the project dir from this script's own location ----------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
PROJECT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

# --- Resolve $HOME robustly (Shortcuts may not set it) ----------------------
if [ -z "${HOME:-}" ]; then
    HOME="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
fi
export HOME

# --- Read MEETGIST_OUTPUT_DIR from scripts/.env and export it for the binary --
# Single value, whitespace/quote tolerant; we deliberately do NOT source .env
# (its values can contain spaces and special characters).
ENV_FILE="$SCRIPTS_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    _out="$(grep -E '^MEETGIST_OUTPUT_DIR=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" -e 's/[[:space:]]*$//')"
    [ -n "$_out" ] && export MEETGIST_OUTPUT_DIR="$_out"
fi
export MEETGIST_SCRIPTS_DIR="$SCRIPTS_DIR"

OUTPUT_DIR="${MEETGIST_OUTPUT_DIR:-$HOME/Documents/meetgist}"
MEETGIST_BIN="${MEETGIST_BIN:-$PROJECT_DIR/.build/release/meetgist}"
# User-scoped state files — avoids /tmp permission clashes if anything ever
# runs as a different user (e.g. an early misconfigured Shortcut as root).
RUNDIR="$HOME/Library/Caches/meetgist"
mkdir -p "$RUNDIR"
PIDFILE="$RUNDIR/meetgist.pid"
LOGFILE="$RUNDIR/meetgist.log"

notify() {
    /usr/bin/osascript -e "display notification \"$1\" with title \"meetgist\"" >/dev/null 2>&1 &
}

is_recording() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

latest_session() {
    ls -dt "$OUTPUT_DIR"/*/ 2>/dev/null | head -1
}

# --- Subcommands ------------------------------------------------------------
case "${1:-toggle}" in
    status)
        if is_recording; then
            echo "● Recording — run 'meetgist' again to stop"
        else
            echo "■ Recording stopped"
        fi
        exit 0
        ;;
    open)
        mkdir -p "$OUTPUT_DIR"
        open "$OUTPUT_DIR" 2>/dev/null || echo "$OUTPUT_DIR"
        exit 0
        ;;
    last)
        latest="$(latest_session)"
        if [ -n "$latest" ]; then
            open "$latest" 2>/dev/null || echo "$latest"
        else
            echo "no sessions yet in $OUTPUT_DIR"
        fi
        exit 0
        ;;
    toggle)
        : # fall through to the start/stop logic below
        ;;
    *)
        echo "usage: $(basename "$0") [status|open|last]   (no arg = start/stop toggle)" >&2
        exit 64
        ;;
esac

# --- Toggle: stop if running, otherwise start -------------------------------
if is_recording; then
    PID=$(cat "$PIDFILE")
    kill -INT "$PID"
    rm -f "$PIDFILE"
    notify "Stopping — processing in background"
else
    if [ ! -x "$MEETGIST_BIN" ]; then
        notify "meetgist binary not found at $MEETGIST_BIN — run ./setup.sh"
        exit 1
    fi
    nohup "$MEETGIST_BIN" record >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    notify "Recording started"
fi
