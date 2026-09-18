#!/bin/sh
set -e
cd "$(dirname "$0")"

if pgrep -f "\.build/release/MeetGistApp" >/dev/null 2>&1; then
    echo "MeetGist is already running (PID $(pgrep -f '\.build/release/MeetGistApp' | tr '\n' ' '))." >&2
    echo "Bringing it to the front instead of starting a second copy." >&2
    osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is (do shell script "pgrep -f \".build/release/MeetGistApp\" | head -n1") ) to true' >/dev/null 2>&1 || true
    exit 0
fi

nohup .build/release/MeetGistApp > /tmp/meetgist.log 2>&1 &
echo "MeetGist started (PID $!). Logs: /tmp/meetgist.log"
