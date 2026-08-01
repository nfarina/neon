"""Sanity-check a trained hey-neon model.

Runs the exported ONNX model over held-out positive clips (should fire) and
adversarial-negative clips (should stay quiet), reporting detection rates at a
few thresholds. This is a smoke test that the model learned the target phrase —
not a substitute for testing in the real deployment environment, where
background noise and mic characteristics dominate false-accept behavior.

Usage (inside the container):
    python /work/scripts/verify_model.py [--threshold 0.5]
"""

import argparse
from pathlib import Path

import numpy as np
from tqdm import tqdm

CLIPS = Path("/work/output/hey_neon/hey_neon")


def score_clips(oww, clip_dir: Path, limit: int):
    """Return the peak model score for each clip (max over the clip's frames)."""
    peaks = []
    files = sorted(clip_dir.glob("*.wav"))[:limit]
    # disable=None silences the bar when stdout isn't a tty (log files)
    for f in tqdm(files, desc=clip_dir.name, leave=False, disable=None):
        oww.reset()  # clear streaming state between clips
        scores = oww.predict_clip(str(f))
        peaks.append(max(s["hey_neon"] for s in scores))
    return np.array(peaks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=200, help="clips per set")
    ap.add_argument(
        "--model",
        default="/work/output/hey_neon/hey_neon.onnx",
        help="path to .onnx or .tflite model",
    )
    ap.add_argument(
        "--real",
        action="store_true",
        help="score held-out real recordings instead of synthetic clips",
    )
    args = ap.parse_args()

    from openwakeword.model import Model

    framework = "tflite" if args.model.endswith(".tflite") else "onnx"
    print(f"model: {args.model} ({framework})")
    oww = Model(wakeword_models=[args.model], inference_framework=framework)

    if args.real:
        # The only evaluation not drawn from the same TTS generator that
        # produced the training data.
        holdout = Path("/work/data/my_voice/holdout")
        sets = {
            "real voice (should fire)": holdout / "positive",
            "real non-wakeword (should stay quiet)": holdout / "negative",
        }
    else:
        sets = {
            "positive_test (should fire)": CLIPS / "positive_test",
            "adversarial_test (should stay quiet)": CLIPS / "negative_test",
        }

    results = {}
    for label, d in sets.items():
        if not d.exists():
            print(f"skipping {label}: {d} not found")
            continue
        results[label] = score_clips(oww, d, args.limit)

    print(f"\n{'set':<40} {'n':>5} {'mean':>7} {'median':>7}")
    print("-" * 62)
    for label, peaks in results.items():
        print(f"{label:<40} {len(peaks):>5} {peaks.mean():>7.3f} {np.median(peaks):>7.3f}")

    print(f"\n{'threshold':<12}" + "".join(f"{label.split()[0]:>20}" for label in results))
    print("-" * 62)
    for t in (0.1, 0.3, 0.5, 0.7, 0.9):
        row = f"{t:<12.1f}"
        for peaks in results.values():
            row += f"{(peaks >= t).mean() * 100:>19.1f}%"
        print(row)
    print("\n(positive column = detection rate, adversarial column = false-accept rate)")


if __name__ == "__main__":
    main()
