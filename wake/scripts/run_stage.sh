#!/usr/bin/env bash
# Container entrypoint: run one (or all) stages of the training pipeline.
# Usage: stage [download|generate|inject|augment|train|export|verify|all|shell]
set -euo pipefail

CONFIG=/work/config/hey_neon.yml
TRAIN=/opt/openwakeword/openwakeword/train.py
MODEL_ONNX=/work/output/hey_neon/hey_neon.onnx

cd /work

CLIPS=/work/output/hey_neon/hey_neon
clip_total() {
  # Guard on -d: ls against a missing dir exits non-zero, which pipefail would
  # turn into a script-killing failure inside the command substitution.
  local n=0 d
  for d in positive_train negative_train positive_test negative_test; do
    if [ -d "$CLIPS/$d" ]; then
      n=$((n + $(ls "$CLIPS/$d" | wc -l)))
    fi
  done
  echo "$n"
}

case "${1:-all}" in
  download)
    python /opt/scripts/download_data.py "${@:2}"
    ;;
  generate)
    # The Piper generation loop grows memory across batches and gets OOM-killed
    # on long runs (survives ~5k clips, dies somewhere past ~18k). It is fully
    # resumable — it counts existing clips per set and tops up the shortfall —
    # so run it in fresh processes until it exits cleanly. Nothing is lost on a
    # kill: clips are written to disk as each batch completes.
    attempt=0
    ok=0
    while [ "$attempt" -lt 40 ]; do
      before=$(clip_total)
      if python "$TRAIN" --training_config "$CONFIG" --generate_clips; then
        ok=1
        echo "generation complete after $attempt restart(s)"
        break
      fi
      after=$(clip_total)
      attempt=$((attempt + 1))
      if [ "$after" -le "$before" ]; then
        echo "generation died without producing clips (was $before, now $after) — aborting" >&2
        exit 1
      fi
      echo "### generator was killed at $after clips; restarting (attempt $attempt)"
    done
    if [ "$ok" != 1 ]; then
      echo "generation still incomplete after $attempt restarts ($(clip_total) clips)" >&2
      exit 1
    fi
    ;;
  augment)
    python "$TRAIN" --training_config "$CONFIG" --augment_clips
    ;;
  train)
    # train.py exports the ONNX model and then tries to convert it to tflite,
    # which always fails here (see scripts/export_tflite.py for why) and takes
    # the exit code down with it. The ONNX model is the real output of this
    # stage, so gate success on that landing rather than on the exit code.
    python "$TRAIN" --training_config "$CONFIG" --train_model || true
    if [ ! -f "$MODEL_ONNX" ]; then
      echo "training finished but produced no ONNX model at $MODEL_ONNX" >&2
      exit 1
    fi
    ;;
  repair)
    python /work/scripts/repair_clips.py "${@:2}"
    ;;
  inject)
    python /work/scripts/inject_voice.py "${@:2}"
    ;;
  export)
    python /work/scripts/export_tflite.py
    ;;
  verify)
    python /work/scripts/verify_model.py "${@:2}"
    ;;
  all)
    python /opt/scripts/download_data.py
    python "$TRAIN" --training_config "$CONFIG" --generate_clips
    python "$TRAIN" --training_config "$CONFIG" --augment_clips
    python "$TRAIN" --training_config "$CONFIG" --train_model || true
    if [ ! -f "$MODEL_ONNX" ]; then
      echo "training finished but produced no ONNX model at $MODEL_ONNX" >&2
      exit 1
    fi
    python /work/scripts/export_tflite.py
    python /work/scripts/verify_model.py
    ;;
  finish)
    # Everything after clip generation, in one go: discard any clip damaged by
    # an interrupted write, fold in the real recordings, then rebuild features
    # and retrain from scratch.
    python /work/scripts/repair_clips.py
    python /work/scripts/inject_voice.py "${@:2}"
    rm -f "$CLIPS"/*.npy   # stale features predate the injected clips
    python "$TRAIN" --training_config "$CONFIG" --augment_clips
    python "$TRAIN" --training_config "$CONFIG" --train_model || true
    if [ ! -f "$MODEL_ONNX" ]; then
      echo "training finished but produced no ONNX model at $MODEL_ONNX" >&2
      exit 1
    fi
    python /work/scripts/export_tflite.py
    echo; echo "===== synthetic held-out clips ====="
    python /work/scripts/verify_model.py
    echo; echo "===== real voice holdout (the number that matters) ====="
    python /work/scripts/verify_model.py --real
    ;;
  shell)
    exec bash "${@:2}"
    ;;
  *)
    echo "Unknown stage: $1" >&2
    echo "expected download|generate|augment|train|export|verify|all|shell" >&2
    exit 1
    ;;
esac
