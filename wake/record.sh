#!/usr/bin/env bash
# Launch the voice capture app and open it in the browser.
# Clips are written as 16 kHz mono WAVs.
#
#   ./record.sh              "hey neon"   -> data/my_voice/
#   ./record.sh jarvis       "hey jarvis" -> data/ab_jarvis/   (A/B control)
#   ./record.sh --phrase "hey whatever" --voice-dir data/whatever
#
# The jarvis preset records the control for comparing our model against
# openWakeWord's pretrained hey_jarvis on the same voice, mic and room:
#   python3 wake/scripts/eval_runtime.py --model wake/output/reference/hey_jarvis_v0.1.onnx \
#           --holdout wake/data/ab_jarvis
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8642
ARGS=()

case "${1:-}" in
  jarvis)
    ARGS=(--phrase "hey jarvis" --voice-dir data/ab_jarvis)
    shift
    ;;
esac

# A bare number stays supported as a port, as before.
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then PORT="$1"; shift; fi

( sleep 1; open "http://localhost:$PORT/" ) &
exec python3 "$DIR/scripts/record_server.py" --port "$PORT" "${ARGS[@]}" "$@"
