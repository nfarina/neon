#!/usr/bin/env bash
# Host-side wrapper: run a pipeline stage inside the Apple Container VM.
#
# Usage: ./run.sh [-d] [download|generate|augment|train|all|shell]
#   -d   detached: the container owns the process and writes to logs/<stage>.log
#
# Long stages should always use -d. Attached runs pipe container stdout through
# this shell, and if that pipe closes (terminal exits, host process killed) the
# container wedges mid-stage blocked on write, still running but making no
# progress. Detached runs log to the mounted volume and depend on no host pipe.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE=hey-neon-train

DETACH=""
if [ "${1:-}" = "-d" ]; then
  DETACH=1
  shift
fi
STAGE="${1:-all}"

# Voice recordings live outside the repo — they are recordings of a real
# person's voice, and this repository is public. See data/README.md. They are
# mounted back to the paths the pipeline has always used, so nothing inside
# the container knows the difference.
RECORDINGS="${NEON_WAKE_RECORDINGS:-$HOME/.config/neon/wake}"
MOUNTS=()
for set in my_voice ab_jarvis; do
  [ -d "$RECORDINGS/$set" ] && MOUNTS+=(--volume "$RECORDINGS/$set:/work/data/$set")
done

# --shm-size: PyTorch DataLoader workers pass batches through /dev/shm, which
# defaults to 64 MB in a container. Training batches (1024+ feature tensors)
# blow past that and workers die with "Bus error"/"No space left on device".
# ${arr[@]+…} rather than a bare "${arr[@]}": under `set -u`, bash 3.2 — which
# is still what /bin/bash is on macOS — treats an empty array expansion as an
# unbound variable and aborts.
COMMON=(--cpus 8 --memory 20g --shm-size 4g --volume "$DIR:/work"
        ${MOUNTS[@]+"${MOUNTS[@]}"})

if [ -n "$DETACH" ]; then
  mkdir -p "$DIR/logs"
  NAME="hey-neon-$STAGE"
  container rm -f "$NAME" >/dev/null 2>&1 || true
  container run -d --name "$NAME" "${COMMON[@]}" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "stage $STAGE > /work/logs/$STAGE.log 2>&1"
  echo "Detached container '$NAME' started."
  echo "  logs:   tail -f $DIR/logs/$STAGE.log"
  echo "  status: container list | grep $NAME"
  echo "  stop:   container stop $NAME"
  exit 0
fi

exec container run --rm -i "${COMMON[@]}" "$IMAGE" "$STAGE" "${@:2}"
