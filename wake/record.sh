#!/usr/bin/env bash
# Launch the voice capture app and open it in the browser.
# Recordings land in data/my_voice/{positive,negative}/ as 16 kHz mono WAVs.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${1:-8642}"
( sleep 1; open "http://localhost:$PORT/" ) &
exec python3 "$DIR/scripts/record_server.py" --port "$PORT"
