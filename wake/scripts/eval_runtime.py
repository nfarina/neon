"""Score held-out recordings through the real Swift wake listener.

Why this exists: `verify_model.py` scores clips with openWakeWord's Python
`predict_clip`, which starts from zero-primed buffers. Zeros make any speech
score high while they drain, so Python reports numbers the deployed listener
does not reproduce — on the v3 holdout, Python said 91.7% detection at
threshold 0.5 where the Swift path delivered 58.3%. `OpenWakeListener` is a
hand-written pipeline (noise priming, 480-sample mel lookback across chunks,
76-frame embedding windows, last 16 scored), and it is what actually runs, so
it is the ground truth for choosing `NEON_OWW_THRESHOLD`.

Each clip is prepended with 4 s of quiet noise, which is the always-on
microphone condition: by the time the phrase arrives the model's history is
full of real audio rather than priming. A bare short clip scores far lower
because the phrase never fills the embedding window.

Runs on the host (stdlib only), not in the container.

    swift build -c release --package-path eyes/shell
    python3 wake/scripts/eval_runtime.py [--model wake/output/v1/hey_neon.onnx]
"""

import argparse
import glob
import os
import random
import re
import shutil
import struct
import subprocess
import tempfile
import wave

SR = 16000
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(REPO, "eyes/shell/.build/release/NeonShell")
HOLDOUT = os.path.join(REPO, "wake/data/my_voice/holdout")


def read_wav(p):
    with wave.open(p, "rb") as w:
        return list(struct.unpack(f"<{w.getnframes()}h", w.readframes(w.getnframes())))


def score(samples, cwd):
    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
        out = subprocess.run([BIN], cwd=cwd, env=dict(os.environ, NEON_OWW_TEST=path),
                             capture_output=True, text=True, timeout=180).stdout
        m = re.search(r"max score: ([0-9.]+)", out)
        return float(m.group(1)) if m else None
    finally:
        os.unlink(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="wake model to test (default: the one in wake/models)")
    ap.add_argument("--lead", type=float, default=4.0, help="seconds of noise lead-in")
    ap.add_argument("--holdout", default=HOLDOUT,
                    help="directory containing positive/ and negative/ "
                         "(default the my_voice holdout; use wake/data/ab_jarvis "
                         "to score the pretrained hey_jarvis control)")
    args = ap.parse_args()
    holdout = os.path.abspath(os.path.expanduser(args.holdout))

    if not os.path.exists(BIN):
        raise SystemExit(f"no release binary at {BIN}\n"
                         f"  swift build -c release --package-path eyes/shell")

    tmp = None
    cwd = REPO
    if args.model:
        # The listener discovers models by walking up from cwd for wake/models,
        # so an alternate model gets its own tree rather than overwriting the
        # one that ships.
        tmp = tempfile.mkdtemp()
        d = os.path.join(tmp, "wake/models")
        os.makedirs(d)
        for f in ("melspectrogram.onnx", "embedding_model.onnx"):
            shutil.copy(os.path.join(REPO, "wake/models", f), d)
        shutil.copy(args.model, os.path.join(d, "hey_neon.onnx"))
        cwd = tmp

    try:
        random.seed(0)
        lead = [int(random.gauss(0, 50)) for _ in range(int(args.lead * SR))]
        print(f"  model:   {args.model or 'wake/models/hey_neon.onnx'}")
        print(f"  clips:   {os.path.relpath(holdout, REPO)}   lead-in: {args.lead}s\n")
        results = {}
        for kind in ("positive", "negative"):
            files = sorted(glob.glob(f"{holdout}/{kind}/*.wav"))
            scores = [s for s in (score(lead + read_wav(f), cwd) for f in files) if s is not None]
            results[kind] = scores
            if scores:
                print(f"  {kind}: n={len(scores)}  mean {sum(scores)/len(scores):.3f}")
            else:
                print(f"  {kind}: none found")

        p, n = results["positive"], results["negative"]
        if not p:
            raise SystemExit(f"no positive clips under {holdout}/positive")
        print(f"\n  {'threshold':<12}{'detection':>12}{'false-accept':>15}")
        print("  " + "-" * 39)
        for t in (0.3, 0.4, 0.5, 0.6, 0.7):
            det = 100 * sum(1 for s in p if s >= t) / len(p)
            fa = f"{100 * sum(1 for s in n if s >= t) / len(n):13.1f}%" if n else f"{'—':>14}"
            print(f"  {t:<12}{det:11.1f}%{fa}")
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
