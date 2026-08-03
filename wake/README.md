# wake — training the "hey neon" model

A local, CPU-only port of [openWakeWord](https://github.com/dscripka/openWakeWord)'s
`automatic_model_training` notebook, running under
[Apple Container](https://github.com/apple/container) (linux/arm64). Produces
`models/hey_neon.onnx`, the wake model Neon actually loads.

The upstream pipeline is Linux-only — Piper, the TTS that synthesizes training
speech, has no macOS support — which is the whole reason for the container. The
project directory mounts at `/work` inside it, so paths in `config/` and
`scripts/` are container paths.

## Layout

```text
build.sh              build the image          -> container build
run.sh                run a pipeline stage     -> container run, project at /work
record.sh             browser recorder for capturing your own voice
status.sh             progress, rate, ETA for whatever stage is running
config/hey_neon.yml   phrase, sample counts, steps, paths
models/               COMMITTED — what ships in the app bundle
data/                 corpora + recordings (gitignored; see data/README.md)
output/               clips, features, trained models per run (gitignored)
logs/                 detached-run stage logs (gitignored)
scripts/
  download_data.py    fetch the public corpora
  record_server.py    serves recorder.html, writes 16 kHz WAVs into data/my_voice
  recorder.html       the recorder UI
  check_voice.py      QC a batch of recordings before training on them
  inject_voice.py     trim, normalize, oversample recordings into the clip sets
  repair_clips.py     delete clips damaged by an interrupted write
  export_tflite.py    ONNX -> TFLite (train.py's own conversion is broken)
  verify_model.py     detection / false-accept rates across thresholds
  run_stage.sh        container entrypoint; dispatches the stages below
```

## The process

```sh
./build.sh              # ~15 min, once
./run.sh -d download    # ~18 GB of corpora into data/
./run.sh -d generate    # Piper synthesizes 42,000 clips  (~9 h)
./record.sh             # capture your own voice  (any time; see below)
./run.sh -d finish      # repair -> inject -> augment -> train -> export -> verify
```

`finish` is the whole back half in one detached run (~3 h). The individual
stages — `repair`, `inject`, `augment`, `train`, `export`, `verify` — can also be
run alone. Every stage is resumable: rerunning skips whatever is already on
disk, so an interrupted run is picked up rather than restarted.

**Use `-d` for anything long.** It detaches the container and logs to
`logs/<stage>.log`. Without it, container stdout pipes through the calling
shell, and if that pipe closes — terminal exits, host process killed — the
container wedges mid-stage: blocked on write, still listed as running, making
no progress. Detached runs depend on no host pipe.

Watch with `./status.sh` (or `./status.sh -w` to refresh), and
`tail -f logs/<stage>.log` for detail.

Generation is the long pole and the memory hog: the Piper loop leaks and gets
OOM-killed somewhere past ~18k clips. The `generate` stage detects the kill and
restarts in a fresh process — clips are written per batch, so nothing is lost.
The 42k-clip run absorbed 3 kills unattended.

## Recording your own voice

Synthetic speech alone does not generalise well to one specific person in one
specific room. `./record.sh` serves a recorder at `localhost:8642` (localhost
rather than `file://` because getUserMedia needs a secure context) that writes
16 kHz mono WAVs into `data/my_voice/`.

Press space, wait for "speak now", say it. It cycles delivery hints — normal,
quieter, across the room, faster, turned away — because forty identical reads
teach far less than forty varied ones. A device selector shows which input is
actually live, since Chrome picks independently of macOS.

Record **negatives too** ("hey leon", "hey neo", "neon" alone): near-misses are
what teach the phrase boundary. Roughly 50 positives and 30 negatives is a
useful batch. Check them before training:

```sh
./run.sh shell -c "python /work/scripts/check_voice.py"
```

`inject_voice.py` then trims each clip, normalises it to the synthetic level,
and oversamples it to ~10% of the positive set (`--ratio`), holding back a
deterministic 25% that is never trained on.

## The hey_jarvis control

Our numbers are only interpretable against a reference. openWakeWord's
pretrained `hey_jarvis` is a professionally trained model of the same
architecture family (`wake/output/reference/hey_jarvis_v0.1.onnx`, 316,738
parameters against our 50,401 — roughly `layer_size` 184 versus our 32), so
running it on the same voice, mic and room separates two very different
problems:

- if jarvis also scores ~75%, the ceiling is the runtime or the measurement,
  and more training data would be wasted effort;
- if jarvis scores ~95%, our model is genuinely the weak part.

```sh
./record.sh jarvis     # ~20 clips of "hey jarvis" -> data/ab_jarvis/
python3 scripts/eval_runtime.py \
    --model output/reference/hey_jarvis_v0.1.onnx \
    --holdout data/ab_jarvis
```

Record them the way you record the neon set — same room, same spread of
distances — or the comparison measures the recording session instead of the
model. The recorder is the same page with a different phrase, deliberately: a
forked copy could differ in pre-roll or level handling and contaminate the
result.

## Deploying to Neon

`models/` is what the shell ships. `eyes/shell/build.sh` copies every `.onnx` in
it into `Neon.app/Contents/Resources/oww/`:

```sh
cp output/hey_neon/hey_neon.onnx models/hey_neon.onnx
eyes/rebuild.sh
```

Alongside the wake model, `models/` holds openWakeWord's two shared feature
extractors, `melspectrogram.onnx` and `embedding_model.onnx`, vendored from the
upstream v0.5.1 release — inputs to every model this pipeline makes, not
per-model artifacts.

A model whose filename contains "neon" arms the openWakeWord path; without one
the shell falls back to the SFSpeech matcher. The `.tflite` export is kept for
other runtimes and is not bundled — the shell uses ONNX Runtime.

**Retune the threshold when you promote a model.** `NEON_OWW_THRESHOLD`
(default in `OpenWakeListener.swift`) is calibrated per-model; models differ in
how hot they run, and a threshold tuned for one is meaningless for another.

## Results

Three evaluations, in increasing order of how much they should be believed.

**Synthetic held-out clips** (200 per set) come from the same TTS generator as
the training data, so this only measures the model against its own
distribution. It is the least meaningful number and the most flattering:
90.5% detection / 1.0% false-accept at threshold 0.5 (`./run.sh verify`).

**Held-out real recordings via Python** (`./run.sh verify --real`) — 12
positives / 8 near-miss negatives of Nick, never trained on. Better, but still
optimistic: `predict_clip` starts from zero-primed buffers, and zeros make any
speech score high while they drain. Reports 91.7% at threshold 0.5.

**Held-out real recordings through the actual Swift listener** — the number
that predicts behavior in the kitchen, because it is the code that runs there:

```sh
swift build -c release --package-path eyes/shell
python3 wake/scripts/eval_runtime.py                        # shipped model
python3 wake/scripts/eval_runtime.py --model wake/output/v1/hey_neon.onnx
```

The shipped model (v4) detects **100% of held-out positives at every threshold
up to 0.95**, scoring 0.968–0.998 on all twelve. Ordinary speech negatives score
**≤0.018**. Those two populations are two orders of magnitude apart, so the
threshold is not trading recall against false accepts — it only decides how much
of a deliberate near-miss to tolerate:

| clip type | score range |
|-----------|-------------|
| true positives (12) | 0.968 – 0.998 |
| near-miss negatives ("hey leon", "hey neo") | 0.788, 0.948, 0.990 |
| ordinary speech negatives (5) | ≤ 0.018 |

Shipped default is **0.8** — below every observed true positive, above all but
the two closest confusions.

Model progression through the Swift path, mean score on the same held-out
recordings:

| model | mean positive | detection |
|-------|---------------|-----------|
| v1 — 5k clips, 6 speakers, no real voice | 0.478 | 58.3% @0.3 |
| v3 — 20k clips, 904 speakers, + real voice | 0.597 | 75.0% @0.4 |
| **v4 — same data, `layer_size` 32 → 192** | **0.989** | **100% @0.8** |
| *reference: openWakeWord's pretrained hey_jarvis* | *0.994* | *100%* |

**Capacity was the dominant factor** — bigger than every data fix combined. v3
and v4 were trained on byte-identical features; only `layer_size` changed. The
config's default of 32 produces 50,401 parameters where openWakeWord's own
published model has 316,738, and that one line cost more accuracy than the
speaker-collapse bug, the trimming bug and 50 real recordings put together. v4
now essentially matches the reference model on the same voice, mic and room.

**Do not tune the threshold from the Python numbers.** They disagree with the
runtime by enough to pick the wrong one — on v3, 91.7% versus 58.3% on identical
clips at 0.5. And with 12 positives and 8 negatives, one clip moves detection 8
points and false-accepts 12.5: the direction is reliable, the precision is not.
More holdout recordings is the cheapest way to sharpen every number here.

## Tuning

- `n_samples` (`config/hey_neon.yml`) — 20,000 currently; the config's own
  recommended minimum. Generation runs ~1.3 clips/s, so this dominates wall time.
- `steps` — 50,000, about 13 steps/s.
- `augmentation_rounds` — reuses each clip N times with independent random
  augmentation. Cheap data multiplication with no extra TTS time.
- `inject_voice.py --ratio` — share of positives that are real speech (0.10).
  Pushing far past 0.20 risks overfitting to a few dozen utterances.
- More AudioSet shards (`download_data.py`, 2 of 38) is the cheapest untried
  quality lever: augmentation mixes background into 75% of clips from a pool of
  only 1,240.

After changing anything upstream of features, delete
`output/hey_neon/hey_neon/*.npy` to force re-augmentation (`finish` does this).

## Deviations from upstream

Six problems in the official notebook/repo, all handled automatically. Listed
so they are not rediscovered.

1. **arm64 dependency swaps.** The notebook pins `tensorflow-cpu==2.8.1` and
   `tensorflow_probability==0.16.0`, neither of which ships aarch64 wheels →
   TF 2.13.1 / tfp 0.21.0. `onnx_tf` depends on `tensorflow-addons` (no aarch64
   wheels, project EOL) but only imports it for exotic ops these models never
   use → installed with `--no-deps` plus a stub module.
2. **Wrong piper-sample-generator repo.** The notebook clones `rhasspy/`, since
   restructured into a package, but `train.py` does
   `from generate_samples import generate_samples` — a top-level module that
   only exists in the `dscripka/` fork. That fork uses `espeak-phonemizer`
   rather than `piper-phonemize`, and needs `pytorch_lightning` to unpickle its
   VitsModel checkpoint.
3. **`augmentation_rounds` was a silent no-op** (patched in the Dockerfile).
   `train.py` duplicates the clip list by `augmentation_rounds`, then passes
   `n_total=len(os.listdir(<clip dir>))` — the *undoubled* count — to
   `compute_features_from_generator`, truncating the generator back to one
   round. Fixed by sizing `n_total` from the duplicated list.
4. **Built-in TFLite conversion always fails** with `KeyError: 'onnx::Flatten_0'`.
   PyTorch names tensors like `onnx::Flatten_0`; `onnx_tf` sanitizes `::` to
   `__` when building the tf.function signature, then looks the tensor up under
   its original name. `export_tflite.py` renames tensors first. The `train`
   stage therefore gates success on the ONNX file landing, not train.py's exit
   code.
5. **The Piper generation loop leaks memory** and is OOM-killed past ~18k clips,
   well beyond anything the notebook exercises. `generate` restarts it in a
   fresh process and continues.
6. **Training needs `--shm-size 4g`.** DataLoader workers pass batches through
   /dev/shm, which defaults to 64 MB in a container; workers die with "Bus
   error" partway through the first step.

Also: AudioSet was restructured from `.tar` to parquet shards (Oct 2025), so
`download_data.py` reads parquet directly rather than following the notebook's
`wget` + `tar` path.

## Things that quietly ruin a wake word model

Each of these was found by measurement, and each looked fine until checked.

- **Speaker collapse.** Piper walks speaker pairs with
  `it.product(range(904), range(904))`, second index fastest, so N clips use
  only `ceil(N/904)` distinct primary voices — six, at 5,000 clips. Every clip
  was a blend anchored on one of six people. Patched to sample pairs randomly,
  which decouples voice coverage from sample count.
- **Over-trimming.** Requiring 40 ms of sustained energy to mark speech onset
  cut the breathy /h/ of "hey" and started clips at the vowel. One held-out clip
  went from 0.947 to **0.029**. It corrupted the training data and the
  evaluation at once, which made the model look unimprovable when it had in fact
  improved. Trim parameters are now validated against untrimmed audio as ground
  truth, and default to timid.
- **Level mismatch.** Synthetic clips peak at −6 dBFS, real recordings at −17 to
  −34, and augmentation only ever attenuates. Loudness would have become a
  reliable cue separating real from synthetic. Recordings are normalized at
  injection, which discards only absolute level and keeps what distance actually
  contributes: reverb, spectral tilt, SNR.
- **Trigger noise.** The keystroke that starts a recording is a broadband
  transient at the head of every positive, and no synthetic clip has one. The
  recorder waits 650 ms before capturing.
- **Evaluating in-distribution.** Scoring against clips from the same TTS
  generator that produced the training data reported 92.7% while the model
  needed three tries in the kitchen. Any real claim needs held-out real audio —
  which is what `verify --real` and `data/my_voice/holdout/` exist for.
