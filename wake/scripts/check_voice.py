"""Quality-check the recordings in data/my_voice/ before they enter training.

Reports level, trimmed speech duration, and flags takes that would hurt the
model: clipped, too quiet, suspiciously short or long, or containing a sharp
transient (a stray keyboard click) after trimming.

Usage (inside the container):
    python /work/scripts/check_voice.py [dir]      # default /work/data/my_voice
    python /work/scripts/check_voice.py /work/data/ab_jarvis
"""

import sys
from pathlib import Path

import numpy as np
import scipy.io.wavfile

sys.path.insert(0, "/work/scripts")
from inject_voice import MIN_USABLE_PEAK, trim_silence  # noqa: E402

VOICE = Path(sys.argv[1] if len(sys.argv) > 1 else "/work/data/my_voice")
SR = 16000


def db(x):
    return 20 * np.log10(max(x, 1e-9))


def analyse(p: Path):
    sr, audio = scipy.io.wavfile.read(p)
    a = audio.astype(np.float32) / 32768.0
    if a.ndim > 1:
        a = a.mean(axis=1)
    t = trim_silence(a)

    peak = float(np.abs(a).max())
    trimmed_peak = float(np.abs(t).max()) if len(t) else 0.0
    dur = len(t) / SR

    # Level gets normalised at injection, so what matters is not how loud the
    # take is but how far the speech sits above the room. Estimate the noise
    # floor from the quietest tenth of the original window.
    fr = SR // 100
    nn = len(a) // fr
    snr = 0.0
    if nn >= 10 and trimmed_peak > 0:
        rms_all = np.sqrt(np.mean(a[: nn * fr].reshape(nn, fr) ** 2, axis=1) + 1e-12)
        floor = float(np.percentile(rms_all, 10))
        speech = float(np.sqrt((t ** 2).mean()))
        snr = db(speech) - db(floor)

    # A click surviving the trim shows up as a very short, very loud excursion
    # relative to the clip's typical level.
    frame = SR // 100
    n = len(t) // frame
    spiky = False
    if n >= 5:
        rms = np.sqrt(np.mean(t[: n * frame].reshape(n, frame) ** 2, axis=1) + 1e-12)
        spiky = bool(rms.max() > np.percentile(rms, 95) * 4.0)

    flags = []
    if peak >= 0.99:
        flags.append("CLIPPED")
    if trimmed_peak < MIN_USABLE_PEAK:
        flags.append("unusable — below noise")
    elif snr < 12:
        flags.append(f"low SNR {snr:.0f} dB")
    if dur < 0.35:
        flags.append("very short")
    if dur > 1.8:
        flags.append("long//no clear gap")
    if spiky:
        flags.append("transient")
    return dict(name=p.name, dur=dur, peak=peak, tpeak=trimmed_peak, snr=snr, flags=flags)


def report(kind: str):
    d = VOICE / kind
    files = sorted(d.glob("*.wav"))
    if not files:
        print(f"\n{kind}: none found in {d}")
        return
    rows = [analyse(p) for p in files]
    durs = np.array([r["dur"] for r in rows])
    peaks = np.array([r["tpeak"] for r in rows])
    snrs = np.array([r["snr"] for r in rows])

    print(f"\n{kind}: {len(rows)} clips")
    print(f"  speech duration  mean {durs.mean():.2f}s   range {durs.min():.2f}-{durs.max():.2f}s")
    print(f"  level as recorded  {db(peaks.min()):.0f} to {db(peaks.max()):.0f} dBFS "
          f"(normalised to -6 dBFS at injection, so this only affects SNR)")
    print(f"  speech-to-room   mean {snrs.mean():.0f} dB   "
          f"range {snrs.min():.0f}-{snrs.max():.0f} dB")

    flagged = [r for r in rows if r["flags"]]
    if flagged:
        print(f"  {len(flagged)} flagged:")
        for r in flagged:
            print(f"    {r['name']}  {r['dur']:.2f}s  {db(r['tpeak']):.0f} dBFS  "
                  f"-> {', '.join(r['flags'])}")
    else:
        print("  no problems found")


if __name__ == "__main__":
    for k in ("positive", "negative"):
        report(k)
    print()
