#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Longfu Xu
#
# Install (or remove) a launchd agent that auto-imports + transcribes new Apple
# Voice Memos every ~10 minutes via scripts/import_voicememos.py.
#
#   install_voicememo_watcher.sh            # seed existing memos, install, start
#   install_voicememo_watcher.sh uninstall  # stop + remove the agent
#   install_voicememo_watcher.sh status     # is it loaded? recent log lines
set -euo pipefail

LABEL="com.meetgist.voicememo-import"
INTERVAL=600   # seconds between scans (~10 min)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORTER="$SCRIPT_DIR/import_voicememos.py"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/meetgist"
LOG="$LOG_DIR/voicememo-import.log"
DOMAIN="gui/$(id -u)"

load_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # Fall back to the legacy API on older macOS.
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
  fi
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
}

case "${1:-install}" in
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL (ledger + transcripts kept)"
    exit 0
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "● loaded: $LABEL (every ${INTERVAL}s)"
    else
      echo "■ not loaded"
    fi
    echo "log: $LOG"
    [ -f "$LOG" ] && tail -n 8 "$LOG" || true
    exit 0
    ;;
  install) : ;;
  *) echo "usage: $(basename "$0") [install|uninstall|status]" >&2; exit 64 ;;
esac

# --- install ---------------------------------------------------------------
if [ ! -x "$PYTHON" ]; then
  echo "error: $PYTHON not found — run 'make setup' first." >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

# Seed: mark every memo currently in the library as already-seen, so only memos
# recorded from now on get transcribed.
echo "seeding existing memos (these will NOT be transcribed)..."
"$PYTHON" "$IMPORTER" --seed

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$IMPORTER</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

load_agent

echo
echo "installed $LABEL — scans every ${INTERVAL}s."
echo "  log:     $LOG"
echo "  ledger:  ~/Library/Caches/meetgist/imported-voicememos.json"
echo "  remove:  $(basename "$0") uninstall"
echo
echo "IMPORTANT — Full Disk Access:"
echo "  A launchd agent can't read the Voice Memos store unless its interpreter"
echo "  has Full Disk Access. If the log shows permission errors / 0 memos found,"
echo "  add this binary in System Settings > Privacy & Security > Full Disk Access:"
echo "    $PYTHON"
