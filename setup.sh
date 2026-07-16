#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
# One-command setup for meetgist.
#   ./setup.sh
# Builds the Swift recorder, creates the Python venv, and bootstraps scripts/.env.
# Safe to re-run; it only does what is missing.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

bold "meetgist setup"
echo

# --- 1. Prerequisites -------------------------------------------------------
missing=0

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not found. Install with:  xcode-select --install"
    missing=1
else
    ok "Xcode Command Line Tools"
fi

if ! command -v swift >/dev/null 2>&1; then
    warn "swift not found (comes with Xcode Command Line Tools)."
    missing=1
else
    ok "swift ($(swift --version 2>/dev/null | head -1))"
fi

if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found. Install Python 3.10+ (e.g. brew install python)."
    missing=1
else
    ok "python3 ($(python3 --version 2>&1))"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found — needed for long-audio chunking. Install:  brew install ffmpeg"
    # not fatal: short recordings work without it
else
    ok "ffmpeg"
fi

if [ "$missing" -ne 0 ]; then
    echo
    bold "Install the missing prerequisites above, then re-run ./setup.sh"
    exit 1
fi

# --- 2. Build the Swift recorder -------------------------------------------
# Only the CLI product: script users don't need the SwiftUI app target (that one
# is `make app`), and this keeps the build fast and free of app-only dependencies.
echo
bold "Building the recorder…"
swift build -c release --product meetgist
ok "binary → .build/release/meetgist"

# --- 3. Python venv + dependencies -----------------------------------------
echo
bold "Setting up the Python environment…"
if [ ! -d scripts/.venv ]; then
    python3 -m venv scripts/.venv
fi
scripts/.venv/bin/python3 -m pip install --quiet --upgrade pip
scripts/.venv/bin/python3 -m pip install --quiet -r scripts/requirements.txt
ok "venv → scripts/.venv"

# --- 4. .env ----------------------------------------------------------------
echo
bold "Configuration…"
if [ ! -f scripts/.env ]; then
    cp scripts/.env.example scripts/.env
    ok "created scripts/.env from the template"
else
    ok "scripts/.env already exists (left untouched)"
fi

chmod +x meetgist-toggle.sh scripts/transcribe_meeting.sh 2>/dev/null || true

# --- 5. Shell aliases -------------------------------------------------------
# Installs (or refreshes) a self-contained block of aliases in your shell rc:
#   meetgist     start / stop recording
#   gist-status  show recording status + latest notes
#   gist-open    open the output folder
#   gist-last    open the most recent session folder
#   gist-tx      transcribe an existing audio file / folder
install_aliases() {
    local rc="$1"
    [ -f "$rc" ] || : > "$rc"
    cp "$rc" "$rc.meetgist-bak" 2>/dev/null || true
    local tmp; tmp="$(mktemp)"
    # Drop any previous meetgist block (new ">>>" markers or legacy "--- meetgist ---").
    awk '
        /# >>> meetgist aliases >>>/ {skip=1}
        /^# --- meetgist/            {skip=1}
        skip==0                     {print}
        /# <<< meetgist aliases <<</ {skip=0; next}
        /^# --- end meetgist ---/    {skip=0; next}
    ' "$rc" > "$tmp"
    {
        printf '\n# >>> meetgist aliases >>>\n'
        printf 'export MEETGIST_HOME="%s"\n' "$PROJECT_DIR"
        printf 'alias meetgist="$MEETGIST_HOME/meetgist-toggle.sh"\n'
        printf 'alias gist-status="$MEETGIST_HOME/meetgist-toggle.sh status"\n'
        printf 'alias gist-open="$MEETGIST_HOME/meetgist-toggle.sh open"\n'
        printf 'alias gist-last="$MEETGIST_HOME/meetgist-toggle.sh last"\n'
        printf 'alias gist-tx="$MEETGIST_HOME/scripts/transcribe_meeting.sh"\n'
        printf '# <<< meetgist aliases <<<\n'
    } >> "$tmp"
    mv "$tmp" "$rc"
}

echo
bold "Installing terminal shortcuts…"
case "$(basename "${SHELL:-/bin/zsh}")" in
    bash) RC="$HOME/.bashrc" ;;
    *)    RC="$HOME/.zshrc" ;;
esac
install_aliases "$RC"
ok "added meetgist / gist-status / gist-open / gist-last / gist-tx → $RC"

# --- 6. Next steps ----------------------------------------------------------
echo
bold "Done. Next steps:"
cat <<EOF

  1. Add your Gemini API key (free at https://aistudio.google.com/apikey):
       open scripts/.env        # set GEMINI_API_KEY=...

  2. (Optional) Choose where recordings are saved:
       set MEETGIST_OUTPUT_DIR in scripts/.env
       (defaults to ~/Documents/meetgist)

  3. Load the new terminal shortcuts (or just open a new terminal):
       source $RC

  4. Grant macOS permissions the first time you record:
       System Settings → Privacy & Security → Screen Recording  (your terminal / Shortcuts.app)
       System Settings → Privacy & Security → Microphone

  5. Use it:
       meetgist        # start recording; run again to stop + transcribe
       gist-status     # is it recording? are the latest notes ready?
       gist-open       # open the notes folder
       gist-tx FILE    # transcribe an existing audio file / folder

EOF
