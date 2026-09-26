#!/bin/sh
set -e
cd "$(dirname "$0")"

PIDS=$(pgrep -f "\.build/(release|debug)/MeetGistApp" || true)

if [ -z "$PIDS" ]; then
    echo "No MeetGist process running."
    exit 0
fi

echo "Killing MeetGist (PID $(echo "$PIDS" | tr '\n' ' '))..."
kill $PIDS 2>/dev/null || true
sleep 1

STILL=$(pgrep -f "\.build/(release|debug)/MeetGistApp" || true)
if [ -n "$STILL" ]; then
    echo "Still running, force killing (PID $(echo "$STILL" | tr '\n' ' '))..."
    kill -9 $STILL 2>/dev/null || true
fi

echo "Done."
