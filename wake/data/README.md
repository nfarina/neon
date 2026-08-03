# wake/data — training corpora and recordings

Everything in this directory except this file is gitignored: ~18 GB of public
corpora, all of it re-downloadable. Nothing here is a build artifact of the
app.

**The voice recordings are no longer here.** They live in
`~/.config/neon/wake/` as of 2026-08-03 — see below.

Recreate the public corpora at any time with:

```sh
cd wake && ./run.sh -d download
```

Every download is resumable and skips what is already present, so re-running it
is cheap and safe.

## What belongs here

| path | size | source | purpose |
|------|------|--------|---------|
| `openwakeword_features_ACAV100M_2000_hrs_16bit.npy` | 16 GB | [davidscripka/openwakeword_features](https://huggingface.co/datasets/davidscripka/openwakeword_features) | ~2,000 h of precomputed negative features — the bulk of every training batch (1024 of 1124). Memory-mapped, never loaded whole. |
| `validation_set_features.npy` | 176 MB | same dataset | ~11 h of features for false-positive-rate estimation and early stopping. |
| `mit_rirs/` | 5.8 MB, 270 wav | [MIT environmental impulse responses](https://mcdermottlab.mit.edu/Reverb/IR_Survey.html) via HF | Room impulse responses. Augmentation convolves clips with these to simulate rooms. |
| `audioset_16k/` | 314 MB, 1,000 wav | [agkphysics/AudioSet](https://huggingface.co/datasets/agkphysics/AudioSet) | Background noise mixed into 75% of augmented clips. |
| `audioset/` | 1.3 GB | — | The raw parquet shards `audioset_16k/` was decoded from. Deletable once decoded; kept only to avoid re-downloading. |
| `fma/` | 220 MB, 240 wav | [rudraml/fma](https://huggingface.co/datasets/rudraml/fma) | 2 h of music, mixed in alongside AudioSet. |
| `hf_cache/` | small | — | HuggingFace `datasets` scratch. Disposable. |
| `my_voice/` | — | recorded locally | **Moved out of the repo**, see below. Mounted back in at this path. |
| `ab_jarvis/` | — | recorded locally | Same, the hey_jarvis control set. |

## my_voice/ — the recordings that matter, and where they went

**They live in `~/.config/neon/wake/` now**, alongside everything else personal
that Neon uses. Override with `NEON_WAKE_RECORDINGS`.

```text
~/.config/neon/wake/
  my_voice/positive/          50 clips of "hey neon"
  my_voice/negative/          33 clips of near-misses and other speech
  my_voice/holdout/positive/  12 clips  ) written by inject_voice.py;
  my_voice/holdout/negative/   8 clips  ) never trained on
  ab_jarvis/positive/         the hey_jarvis A/B control
```

They used to be committed, deliberately: they cannot be regenerated, and git
was the backup. That stopped being tenable when the repo went public on
2026-08-03 — `my_voice/` is 103 recordings of a real person's voice, and
publishing those as a side effect of open-sourcing a kitchen assistant is not
a trade anyone would choose on purpose.

**Nothing in the pipeline changed.** `run.sh` bind-mounts both sets back to
`/work/data/my_voice` and `/work/data/ab_jarvis`, so every script inside the
container still finds them where it always did. The host-side scripts
(`record_server.py`, `eval_runtime.py`, `status.sh`) resolve
`~/.config/neon/wake` directly.

**They are no longer backed up by being committed.** That was a real benefit of
the old arrangement and it is gone; `~/.config/` needs to be in whatever backs
up this machine. If you clear that directory the recordings are gone, and with
them the only real-voice measurement this pipeline has.

Captured with `./record.sh`, which serves a browser recorder at
`localhost:8642` and writes 16 kHz mono WAVs straight into `positive/` and
`negative/`.

`holdout/` is a copy written during injection, not a separate recording
session: a ~25% split excluded from training so there is one honest measure of
real-voice performance. Every other evaluation in this pipeline scores clips
produced by the same TTS generator that made the training data, which flatters
the model badly — an early model measured 92.7% that way while needing three
attempts to trigger in the kitchen.

**The split is sticky.** A clip that has been held out once stays held out;
only never-assigned recordings are drawn on, and the set grows toward 25% as
the collection grows. Re-splitting at random each run would quietly change the
benchmark whenever recordings were added, making a model trained today
incomparable to one trained last week. Which is to say: adding recordings is
safe, but **deleting `holdout/` resets the benchmark** and old numbers stop
being comparable.

Two properties of the recordings matter more than their count:

- **Acoustic variety.** Distance, angle, pace, and volume. Absolute loudness is
  normalized away at injection, but the reverb and spectral character of
  standing across the room is exactly what the synthetic clips lack.
- **Near-miss negatives.** "hey leon", "hey neo", "neon" alone, "hey" alone.
  These teach the phrase boundary. General speech is much less informative.

Check a batch before training on it:

```sh
./run.sh shell -c "python /work/scripts/check_voice.py"
```

It reports speech duration, speech-to-room SNR, and flags clipping, takes below
the noise floor, and stray transients.

## Sizing

The 16 GB feature file dominates. It is the openWakeWord project's own
precomputed negative set and is what keeps false-accept rates low; training
reads it lazily via memory-map, so it costs disk rather than RAM.

For a bigger run, more AudioSet shards is the cheapest quality lever —
`download_data.py` takes `n_shards` (2 of 38 currently), and augmentation mixes
background into three quarters of all clips from a pool of only 1,240.
