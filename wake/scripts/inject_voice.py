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

# Piper's synthetic clips peak around -6 dBFS; real recordings come in anywhere
# from -17 to -34 depending on distance. Augmentation then applies Gain with
# max_gain_in_db=0 — it only attenuates, by up to 18 dB — so untouched real
# clips would end up far quieter than any synthetic one and loudness itself
# would separate the two populations. Normalising to the synthetic level keeps
# what distance actually contributes (reverb, spectral tilt, SNR) and lets
# augmentation supply the level variation for both populations equally.
NORM_PEAK = 0.5          # -6 dBFS
MIN_USABLE_PEAK = 0.005  # -46 dBFS; below this a take is noise, not speech


def trim_silence(audio: np.ndarray, margin_ms: int = 400, min_run_ms: int = 10,
                 thresh_factor: float = 0.03) -> np.ndarray:
    """Trim to the spoken region, erring heavily on the side of keeping audio.

    Speech is required to *sustain* above the threshold for min_run_ms before it
    counts as the start, so a keyboard click cannot anchor the boundary. The
    threshold is relative to a high percentile rather than the peak, so one loud
    transient cannot raise the bar above the actual speech.

    The defaults are deliberately timid. Earlier, stricter values (0.15 / 120ms /
    40ms) cut the breathy /h/ onset of "hey" and started the clip at the vowel;
    measured against the model, that dropped mean score on held-out real
    recordings from 0.88 to 0.71 and detection at 0.5 from 100% to 75% — and the
    same damage went into the training copies. Trimming buys only repositioning
    freedom during augmentation, which is worth far less than the phrase being
    intact, so when in doubt this keeps the audio.
    """
    if audio.dtype != np.float32:
        audio = audio.astype(np.float32) / 32768.0
    frame = SR // 100  # 10 ms
    n = len(audio) // frame
    if n < 5:
        return audio
    rms = np.sqrt(np.mean(audio[: n * frame].reshape(n, frame) ** 2, axis=1) + 1e-12)
    thresh = max(np.percentile(rms, 95) * thresh_factor, 0.002)

    above = (rms > thresh).astype(int)
    k = max(1, min_run_ms // 10)
    runs = np.convolve(above, np.ones(k, dtype=int), mode="valid") >= k
    starts = np.where(runs)[0]
    if len(starts) == 0:  # nothing sustained; fall back to any energy at all
        loud = np.where(above)[0]
        if len(loud) == 0:
            return audio
        lo_f, hi_f = loud[0], loud[-1] + 1
    else:
        lo_f, hi_f = starts[0], starts[-1] + k

    # Extend by the margin, but stop short of any isolated transient. Without
    # this, a click landing within margin_ms of the speech gets pulled in even
    # though it never anchored the boundary.
    pad = margin_ms // 10
    spike = rms > max(thresh * 4, np.percentile(rms, 95) * 2.5)

    lo_f2 = lo_f
    while lo_f2 > max(0, lo_f - pad) and not spike[lo_f2 - 1]:
        lo_f2 -= 1
    hi_f2 = hi_f
    while hi_f2 < min(n, hi_f + pad) and not spike[hi_f2]:
        hi_f2 += 1

    return audio[lo_f2 * frame:hi_f2 * frame]


def normalize(audio: np.ndarray) -> np.ndarray:
    peak = float(np.abs(audio).max())
    if peak < MIN_USABLE_PEAK:
        return None
    return audio * (NORM_PEAK / peak)


def load_trimmed(p: Path):
    """Read, trim to the spoken region, and level-match to the synthetic clips."""
    sr, audio = scipy.io.wavfile.read(p)
    if sr != SR:
        raise ValueError(f"{p.name}: expected {SR} Hz, got {sr}")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    trimmed = trim_silence(audio)
    if len(trimmed) < SR * 0.25:  # under 250 ms of speech is a bad take
        return None
    return normalize(trimmed)


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

    # The holdout is sticky: a clip that has been held out before stays held
    # out. Re-splitting at random on every run would silently change the
    # benchmark whenever new recordings are added, so a model trained today
    # could not be compared against one trained last week. Only clips that have
    # never been assigned get drawn on, and the set grows toward holdout_frac
    # as the recording collection grows.
    hd = HOLDOUT / kind
    hd.mkdir(parents=True, exist_ok=True)
    already = {f.name for f in hd.glob("*.wav")}

    n_hold = max(1, int(len(clips) * holdout_frac)) if len(clips) >= 4 else 0
    hold = [c for c in clips if c[0].name in already]
    fresh = [c for c in clips if c[0].name not in already]
    rng.shuffle(fresh)
    if len(hold) < n_hold:
        take = n_hold - len(hold)
        hold += fresh[:take]
        fresh = fresh[take:]
    train = fresh

    carried = len(already & {c[0].name for c in clips})
    for f in hd.glob("*.wav"):
        f.unlink()   # rewritten below; trimming/normalisation may have changed
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
    carried_note = f", {carried} carried over" if carried else ""
    print(f"{kind}: {len(src)} recordings -> {len(train)} train (x{reps} = {written} clips), "
          f"{len(hold)} holdout{carried_note}, mean speech {dur:.2f}s")
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
    # Count only Piper's clips. Including a previous injection's myvoice_*
    # files would raise the target on every rerun, compounding the real-speech
    # share upward each time the stage is repeated.
    n_synth = len([p for p in (CLIPS / "positive_train").glob("*.wav")
                   if not p.name.startswith("myvoice_")])
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
