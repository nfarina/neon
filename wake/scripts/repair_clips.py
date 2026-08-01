"""Delete truncated or unreadable clips so the generate stage can top them back up.

If the machine loses power or a container is force-killed mid-write, a WAV can
be left with a header promising more audio than the file actually contains.
Generation would not notice — it only counts files — and augmentation would
later choke on the corpse. This checks the declared data size against the real
file size and removes anything that does not line up.

Safe to run any time; it only ever deletes files that are already unusable.

Usage (inside the container):
    python /work/scripts/repair_clips.py [--dry-run]
"""

import argparse
import wave
from pathlib import Path

CLIPS = Path("/work/output/hey_neon/hey_neon")
SETS = ("positive_train", "positive_test", "negative_train", "negative_test")
MIN_FRAMES = 1600  # 0.1 s at 16 kHz — anything shorter is a failed write


def bad_reason(p: Path):
    """Return why this clip is unusable, or None if it is fine."""
    try:
        size = p.stat().st_size
        if size < 100:
            return "empty"
        with wave.open(str(p), "rb") as w:
            frames = w.getnframes()
            declared = frames * w.getnchannels() * w.getsampwidth()
            if frames < MIN_FRAMES:
                return f"too short ({frames} frames)"
            # 44-byte canonical header; allow slack for extra chunks
            if size < declared:
                return f"truncated (header claims {declared}B, file is {size}B)"
    except Exception as e:
        return f"unreadable ({type(e).__name__})"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    total = removed = 0
    for s in SETS:
        d = CLIPS / s
        if not d.is_dir():
            continue
        bad = []
        files = list(d.glob("*.wav"))
        for p in files:
            r = bad_reason(p)
            if r:
                bad.append((p, r))
        total += len(files)
        for p, r in bad[:5]:
            print(f"  {s}/{p.name}: {r}")
        if len(bad) > 5:
            print(f"  ... and {len(bad) - 5} more in {s}")
        if bad and not args.dry_run:
            for p, _ in bad:
                p.unlink()
        removed += len(bad)
        print(f"{s}: {len(files)} clips, {len(bad)} bad{'' if args.dry_run else ' (deleted)'}")

    print(f"\nchecked {total} clips, {removed} unusable")
    if removed and not args.dry_run:
        print("re-run ./run.sh -d generate to regenerate the missing clips")


if __name__ == "__main__":
    main()
