#!/usr/bin/env bash
# Container entrypoint: run one (or all) stages of the training pipeline.
# Usage: stage [download|generate|inject|augment|train|export|verify|all|shell]
set -euo pipefail

CONFIG=/work/config/hey_neon.yml
TRAIN=/opt/openwakeword/openwakeword/train.py
MODEL_ONNX=/work/output/hey_neon/hey_neon.onnx

cd /work

case "${1:-all}" in
  download)
    python /opt/scripts/download_data.py "${@:2}"
    ;;
  generate)
    python "$TRAIN" --training_config "$CONFIG" --generate_clips
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
  shell)
    exec bash "${@:2}"
    ;;
  *)
    echo "Unknown stage: $1" >&2
    echo "expected download|generate|augment|train|export|verify|all|shell" >&2
    exit 1
    ;;
esac
