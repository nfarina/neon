"""Fold real recordings from data/my_voice/ into the training clip sets.

Three things happen here beyond copying files:

1. **Silence trimming.** Recordings are a fixed 2 s window with the phrase
   somewhere inside; synthetic clips are ~1 s of pure speech which augmentation
   then positions randomly inside a 2 s frame. Trimming to the spoken region
   makes real clips behave like synthetic ones instead of being locked to one
   position in the frame.

2. **Oversampling.** A few dozen real clips against 20,000 synthetic ones would
   be statistical noise. Each is duplicated until real speech makes up
   --ratio of the positive set. The duplicates are not identical in the end:
   augmentation applies independent random reverb/noise/gain/pitch to each.

3. **A holdout split.** A fraction of recordings is set aside, never trained on,
   and copied to data/my_voice/holdout/. `verify_model.py --real` scores against
   those — the only honest measure of real-voice performance, since every other
   evaluation clip comes from the same TTS generator as the training data.

Usage (inside the container):
    python /work/scripts/inject_voice.py [--ratio 0.10] [--holdout 0.25]
"""

import argparse
import shutil
from pathlib import Path

import numpy as np
import scipy.io.wavfile

VOICE = Path("/work/data/my_voice")
CLIPS = Path("/work/output/hey_neon/hey_neon")
HOLDOUT = VOICE / "holdout"
SR = 16000


def trim_silence(audio: np.ndarray, margin_ms: int = 120) -> np.ndarray:
    """Trim to the spoken region using a peak-relative energy threshold."""
    if audio.dtype != np.float32:
        audio = audio.astype(np.float32) / 32768.0
    frame = SR // 100  # 10 ms
    n = len(audio) // frame
    if n < 3:
        return audio
    rms = np.sqrt(np.mean(audio[: n * frame].reshape(n, frame) ** 2, axis=1) + 1e-12)
    thresh = max(rms.max() * 0.12, 0.004)
    loud = np.where(rms > thresh)[0]
    if len(loud) == 0:
        return audio
    pad = margin_ms // 10
    lo = max(0, loud[0] - pad) * frame
    hi = min(n, loud[-1] + 1 + pad) * frame
    return audio[lo:hi]


def load_trimmed(p: Path):
    sr, audio = scipy.io.wavfile.read(p)
    if sr != SR:
        raise ValueError(f"{p.name}: expected {SR} Hz, got {sr}")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    trimmed = trim_silence(audio)
    if len(trimmed) < SR * 0.25:  # under 250 ms of speech is a bad take
        return None
    return trimmed


def write(path: Path, audio: np.ndarray):
    scipy.io.wavfile.write(path, SR, (np.clip(audio, -1, 1) * 32767).astype(np.int16))


def inject(kind: str, train_dir: Path, target: int, holdout_frac: float, rng):
    src = sorted((VOICE / kind).glob("*.wav"))
    if not src:
        print(f"no {kind} recordings in {VOICE / kind} — skipping")
        return 0

    clips, skipped = [], []
    for p in src:
        a = load_trimmed(p)
        (clips.append((p, a)) if a is not None else skipped.append(p.name))
    if skipped:
        print(f"  skipped {len(skipped)} near-silent {kind} take(s): {', '.join(skipped[:4])}")
    if not clips:
        return 0

    n_hold = max(1, int(len(clips) * holdout_frac)) if len(clips) >= 4 else 0
    rng.shuffle(clips)
    hold, train = clips[:n_hold], clips[n_hold:]

    hd = HOLDOUT / kind
    hd.mkdir(parents=True, exist_ok=True)
    for f in hd.glob("*.wav"):
        f.unlink()
    for p, a in hold:
        write(hd / p.name, a)

    train_dir.mkdir(parents=True, exist_ok=True)
    for f in train_dir.glob("myvoice_*.wav"):
        f.unlink()  # clear a previous injection so re-running doesn't stack

    reps = max(1, round(target / len(train))) if train else 0
    written = 0
    for p, a in train:
        for r in range(reps):
            write(train_dir / f"myvoice_{p.stem}_{r:03d}.wav", a)
            written += 1

    dur = np.mean([len(a) for _, a in clips]) / SR
    print(f"{kind}: {len(src)} recordings -> {len(train)} train (x{reps} = {written} clips), "
          f"{len(hold)} holdout, mean speech {dur:.2f}s")
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ratio", type=float, default=0.10,
                    help="target share of the positive set that is real speech")
    ap.add_argument("--holdout", type=float, default=0.25,
                    help="fraction of recordings reserved for honest evaluation")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    n_synth = len(list((CLIPS / "positive_train").glob("*.wav")))
    if n_synth == 0:
        print("warning: no synthetic clips found — run the generate stage first")
    target = max(200, int(n_synth * args.ratio))
    print(f"{n_synth} synthetic positives present; targeting ~{target} real-derived clips "
          f"({args.ratio:.0%})\n")

    inject("positive", CLIPS / "positive_train", target, args.holdout, rng)
    inject("negative", CLIPS / "negative_train", target, args.holdout, rng)

    print("\nnext: ./run.sh -d augment   (delete stale *.npy first), then train")


if __name__ == "__main__":
    main()
