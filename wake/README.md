# hey-neon

Custom [openWakeWord](https://github.com/dscripka/openWakeWord) wake word model
for the phrase **"hey neon"**, trained locally on Apple Silicon using
[Apple Container](https://github.com/apple/container) (linux/arm64, CPU-only).

Adapted from openWakeWord's `automatic_model_training.ipynb` (see
`scripts/_reference_notebook.ipynb`), whose pipeline officially supports Linux
only — hence the container.

## Layout

```
Dockerfile            linux/arm64 training environment (openwakeword, piper TTS, torch, TF)
build.sh              build the image        -> container build
run.sh                run a pipeline stage   -> container run (project mounted at /work)
config/hey_neon.yml   training configuration (phrase, sample counts, steps, paths)
scripts/download_data.py   fetches ~20 GB of shared training data into data/
scripts/export_tflite.py   ONNX -> TFLite conversion (train.py's own step is broken)
scripts/verify_model.py    detection / false-accept rates across thresholds
models/               the shipped model — committed, this is what Neon loads
data/                 downloaded datasets (gitignored, reusable across models)
output/hey_neon/      generated clips, features, and the final .onnx/.tflite models
logs/                 detached-run stage logs (gitignored)
```

`data/`, `output/`, and `logs/` are gitignored: ~19 GB of downloaded corpora,
synthesized clips, and extracted features, all reproducible from this pipeline.
Only the pipeline and the trained model in `models/` are committed. Promote a
new run by copying `output/<name>/<name>.onnx` into `models/`.

## Deploying to Neon

`models/` is what the shell ships. `eyes/shell/build.sh` copies every `.onnx`
in it into `Neon.app/Contents/Resources/oww/`, so deploying a new model is:

```sh
cp output/<name>/<name>.onnx models/hey_neon.onnx
eyes/rebuild.sh
```

Alongside the wake model, `models/` holds openWakeWord's two shared feature
extractors, `melspectrogram.onnx` and `embedding_model.onnx`, vendored from the
upstream v0.5.1 release — they are inputs to every model this pipeline makes,
not per-model artifacts.

A model whose filename contains "neon" is what arms the openWakeWord path;
without one the shell falls back to the SFSpeech matcher. The `.tflite` export
is kept for other runtimes and is not bundled — the shell uses ONNX Runtime.

## Results

Trained model, measured on 300 held-out clips per set (`./run.sh verify`).
ONNX and TFLite produce identical scores.

| threshold | detection rate | false-accept (adversarial near-misses) |
|-----------|----------------|----------------------------------------|
| 0.3       | 93.7%          | 1.3%                                   |
| 0.5       | 92.7%          | 1.0%                                   |
| 0.7       | 90.7%          | 0.0%                                   |

0.5–0.7 is a reasonable starting threshold; tune against real recordings from
the actual deployment environment, since mic and room acoustics dominate
real-world false-accept behavior.

## Usage

```sh
./build.sh             # build image (~10-20 min first time)
./run.sh -d download   # ~20 GB: negative features, RIRs, background audio
./run.sh -d generate   # synthesize "hey neon" clips with Piper TTS (~1.5 hr)
./run.sh -d augment    # RIR + background-noise augmentation, feature extraction
./run.sh -d train      # train, export output/hey_neon/hey_neon.onnx (~35 min)
./run.sh export        # convert to hey_neon.tflite
./run.sh verify        # detection / false-accept rates
./run.sh shell         # interactive shell in the container for debugging
```

Every stage is resumable — rerunning skips work already on disk. `./run.sh -d all`
runs the whole pipeline end to end.

**Use `-d` for anything long.** It runs the container detached, logging to
`logs/<stage>.log`. Without it, container stdout is piped through the calling
shell, and if that pipe closes (host process killed, terminal exits) the
container wedges mid-stage — blocked on write, still listed as running, making
no progress. Detached runs depend on no host-side pipe.

Watch progress with `tail -f logs/generate.log`, and check liveness with
`container list | grep hey-neon`.

## Verifying

```sh
./run.sh verify                                                  # ONNX
./run.sh verify --model /work/output/hey_neon/hey_neon.tflite    # TFLite
```

Reports detection rate on held-out positive clips vs. false-accept rate on
adversarial negatives, across thresholds.

## Tuning

- `n_samples` in `config/hey_neon.yml` — 5,000 baseline; 20,000+ recommended
  for best quality (generation time scales linearly, ~1.5 clips/sec).
- `augmentation_rounds` — reuses each clip N times with different random
  augmentation. Cheap way to multiply data without more TTS time.
- `steps` — training steps (20,000 baseline, ~13 steps/sec).
- Re-run `generate` → `augment` → `train` after changing. Delete the stale
  `output/hey_neon/hey_neon/*.npy` features to force re-augmentation.

## Deviations from upstream

This pipeline works around four problems in the official notebook/repo. All are
handled automatically; listed here so they aren't rediscovered.

1. **arm64 dependency swaps.** The notebook pins `tensorflow-cpu==2.8.1` and
   `tensorflow_probability==0.16.0`, neither of which ships aarch64 wheels →
   TF 2.13.1 / tfp 0.21.0 instead. `onnx_tf` depends on `tensorflow-addons`
   (no aarch64 wheels, project EOL) but only imports it for exotic ops these
   models never use → installed with `--no-deps` plus a stub module.
2. **Wrong piper-sample-generator repo.** The notebook clones `rhasspy/`, which
   has since been restructured into a package, but `train.py` does
   `from generate_samples import generate_samples` — a top-level module that
   only exists in the `dscripka/` fork. That fork also uses `espeak-phonemizer`
   rather than `piper-phonemize`, and needs `pytorch_lightning` to unpickle its
   VitsModel checkpoint.
3. **`augmentation_rounds` was a silent no-op** (patched in the Dockerfile).
   `train.py` duplicates the clip list by `augmentation_rounds`, then passes
   `n_total=len(os.listdir(<clip dir>))` — the *undoubled* count — to
   `compute_features_from_generator`, truncating the generator back to exactly
   one round. Fixed by sizing `n_total` from the duplicated list.
4. **Built-in TFLite conversion always fails** with
   `KeyError: 'onnx::Flatten_0'`. PyTorch names tensors like `onnx::Flatten_0`;
   `onnx_tf` sanitizes `::` to `__` when building the tf.function signature but
   then looks the tensor up under its original name. `scripts/export_tflite.py`
   renames the tensors first. The `train` stage therefore treats the ONNX file
   landing — not train.py's exit code — as its success condition.

Also note the AudioSet dataset was restructured from `.tar` files to parquet
shards (Oct 2025), so `download_data.py` reads parquet directly rather than
following the notebook's `wget` + `tar` path.

## Testing with a microphone

On the host: `pip install openwakeword`, then run its
`examples/detect_from_microphone.py` with
`--model_path output/hey_neon/hey_neon.onnx`.
