"""Download training data for openWakeWord custom model training.

Mirrors the data cells of openWakeWord's automatic_model_training.ipynb.
Everything lands in /work/data (host: hey-neon/data), and every step is
resumable/skippable, so re-running after a failure is safe.
"""

import os
import subprocess
import sys
from pathlib import Path

DATA = Path("/work/data")
DATA.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("HF_HOME", str(DATA / "hf_cache"))

import numpy as np  # noqa: E402
import scipy.io.wavfile  # noqa: E402
import datasets  # noqa: E402
from tqdm import tqdm  # noqa: E402


def wget(url: str, dest: Path):
    """Resumable download; skips nothing on retry, wget -c handles partials."""
    print(f"==> {dest.name}")
    subprocess.run(["wget", "-c", "-q", "--show-progress", "-O", str(dest) + ".part", url], check=True)
    os.rename(str(dest) + ".part", dest)


def download_rirs():
    out = DATA / "mit_rirs"
    if out.exists() and len(list(out.glob("*.wav"))) >= 270:
        print("MIT RIRs already present, skipping")
        return
    out.mkdir(exist_ok=True)
    print("==> MIT room impulse responses")
    ds = datasets.load_dataset(
        "davidscripka/MIT_environmental_impulse_responses", split="train", streaming=True
    )
    for row in tqdm(ds):
        name = row["audio"]["path"].split("/")[-1]
        scipy.io.wavfile.write(
            out / name, 16000, (row["audio"]["array"] * 32767).astype(np.int16)
        )


def download_audioset(n_shards: int = 2):
    # The agkphysics/AudioSet repo was restructured (Oct 2025) from .tar files
    # to ~700 MB parquet shards; each bal_train shard holds ~1.6 h of clips.
    out = DATA / "audioset_16k"
    if out.exists() and len(list(out.glob("*.wav"))) >= 1000:
        print("AudioSet clips already present, skipping")
        return
    out.mkdir(exist_ok=True)
    raw = DATA / "audioset"
    raw.mkdir(exist_ok=True)
    shards = []
    for i in range(n_shards):
        shard = raw / f"bal_train_{i:02d}.parquet"
        if not shard.exists():
            wget(
                f"https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train/{i:02d}.parquet",
                shard,
            )
        shards.append(str(shard))
    print("==> decoding AudioSet parquet -> 16 kHz wav")
    # Read parquet directly with pyarrow: the shards' embedded features
    # metadata was written by a newer `datasets` than our pinned 2.14.6.
    import io
    import pyarrow.parquet as pq
    import soundfile as sf
    from scipy.signal import resample_poly

    for shard in shards:
        pf = pq.ParquetFile(shard)
        for batch in tqdm(pf.iter_batches(columns=["audio"], batch_size=16)):
            for rec in batch.column("audio").to_pylist():
                name = rec["path"].split("/")[-1].replace(".flac", ".wav")
                wav, sr = sf.read(io.BytesIO(rec["bytes"]), dtype="float32")
                if wav.ndim > 1:
                    wav = wav.mean(axis=1)
                if sr != 16000:
                    wav = resample_poly(wav, 16000, sr)
                scipy.io.wavfile.write(
                    out / name, 16000, (wav * 32767).astype(np.int16)
                )


def download_fma(n_hours: float = 2.0):
    out = DATA / "fma"
    target = int(n_hours * 3600 // 30)  # FMA "small" is 30-second clips
    if out.exists() and len(list(out.glob("*.wav"))) >= target:
        print("FMA clips already present, skipping")
        return
    out.mkdir(exist_ok=True)
    print(f"==> Free Music Archive ({n_hours} hours)")
    ds = datasets.load_dataset("rudraml/fma", name="small", split="train", streaming=True)
    ds = iter(ds.cast_column("audio", datasets.Audio(sampling_rate=16000)))
    for _ in tqdm(range(target)):
        row = next(ds)
        name = row["audio"]["path"].split("/")[-1].replace(".mp3", ".wav")
        scipy.io.wavfile.write(
            out / name, 16000, (row["audio"]["array"] * 32767).astype(np.int16)
        )


def download_features():
    base = "https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/"
    for fname in [
        "openwakeword_features_ACAV100M_2000_hrs_16bit.npy",  # ~16 GB negative features
        "validation_set_features.npy",  # ~11 hrs validation features
    ]:
        dest = DATA / fname
        if dest.exists():
            print(f"{fname} already present, skipping")
            continue
        wget(base + fname, dest)


if __name__ == "__main__":
    steps = sys.argv[1:] or ["rirs", "audioset", "fma", "features"]
    if "rirs" in steps:
        download_rirs()
    if "audioset" in steps:
        download_audioset()
    if "fma" in steps:
        download_fma()
    if "features" in steps:
        download_features()
    print("Data download complete.")
