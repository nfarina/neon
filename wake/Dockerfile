# Training environment for openWakeWord custom models on linux/arm64
# (adapted from openWakeWord's automatic_model_training.ipynb, which targets
# x86 Colab — TF/piper-phonemize pins are swapped for aarch64-compatible ones)

FROM python:3.10-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ca-certificates ffmpeg libsndfile1 build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# PyTorch CPU (PyPI aarch64 wheels are CPU-only already)
RUN pip install torch==2.1.2 torchaudio==2.1.2 numpy==1.24.4

# TensorFlow + ONNX->TFLite conversion chain.
# Notebook pins tensorflow-cpu==2.8.1 / tfp==0.16.0, which have no aarch64
# wheels; TF >= 2.13 publishes official aarch64 wheels and tfp 0.21 matches it.
RUN pip install tensorflow==2.13.1 tensorflow_probability==0.21.0
# onnx_tf declares a dep on tensorflow-addons (no aarch64 wheels, project EOL);
# install without deps and satisfy its eager import with a stub module — the
# addons ops (Hardmax etc.) are never used by openWakeWord's DNN models.
COPY scripts/tensorflow_addons_stub.py /usr/local/lib/python3.10/site-packages/tensorflow_addons.py
RUN pip install onnx==1.14.1 PyYAML && \
    pip install --no-deps onnx_tf==1.10.0 && \
    python -c "from onnx_tf.backend import prepare; print('onnx_tf import OK')"

# Synthetic TTS clips. openWakeWord's train.py does `from generate_samples import
# generate_samples`, which only exists at the top level of dscripka's fork —
# rhasspy's upstream has since been restructured into a package. The default
# checkpoint that fork expects still comes from rhasspy's v1.0.0 release.
# espeak-phonemizer (this fork's phonemizer) needs libespeak-ng at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends espeak-ng \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/dscripka/piper-sample-generator && \
    wget -q -O piper-sample-generator/models/en-us-libritts-high.pt \
      'https://github.com/rhasspy/piper-sample-generator/releases/download/v1.0.0/en-us-libritts-high.pt'
# pytorch_lightning is required to unpickle the VitsModel checkpoint
# (torch.load does a full pickle load; torch 2.1's weights_only=False default).
RUN pip install espeak-phonemizer webrtcvad==2.0.10 pytorch_lightning==2.1.3 && \
    python -c "import sys; sys.path.insert(0, '/opt/piper-sample-generator'); \
from generate_samples import generate_samples; print('generate_samples import OK')"

# Speaker diversity fix. Upstream walks speaker pairs with
# it.cycle(it.product(range(n), range(n))), which advances the SECOND index
# fastest — so N generated clips only ever use ceil(N/904) distinct primary
# speakers. At 5,000 clips that is 6 of 904 voices, and every clip is a 50/50
# blend anchored on one of those six. Sampling pairs at random decouples voice
# coverage from sample count, so even a small run spans the whole speaker space.
RUN cd /opt/piper-sample-generator && \
    python - <<'PY' && grep -n "randrange" generate_samples.py
import re
src = open("generate_samples.py").read()
old = "speakers_iter = it.cycle(it.product(range(num_speakers), range(num_speakers)))"
new = ("speakers_iter = iter(lambda: (random.randrange(num_speakers), "
       "random.randrange(num_speakers)), None)")
assert src.count(old) == 1, f"expected 1 speakers_iter site, found {src.count(old)}"
src = src.replace(old, new)
assert "\nimport random\n" not in src
src = src.replace("import argparse\n", "import argparse\nimport random\n", 1)
open("generate_samples.py", "w").write(src)
print("speaker sampling patched to random pairs")
PY

# openWakeWord itself, plus its pretrained feature-extractor models
RUN git clone --depth 1 https://github.com/dscripka/openwakeword && \
    pip install -e ./openwakeword && \
    mkdir -p openwakeword/openwakeword/resources/models && \
    cd openwakeword/openwakeword/resources/models && \
    wget -q https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx && \
    wget -q https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.tflite && \
    wget -q https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx && \
    wget -q https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.tflite

# Remaining training dependencies (same pins as the official notebook)
RUN pip install \
    mutagen==1.47.0 \
    torchinfo==1.8.0 \
    torchmetrics==1.2.0 \
    speechbrain==0.5.14 \
    audiomentations==0.33.0 \
    torch-audiomentations==0.11.0 \
    acoustics==0.2.6 \
    pronouncing==0.2.0 \
    datasets==2.14.6 \
    pyarrow==12.0.1 \
    deep-phonemizer==0.0.19

# Fix upstream bug: the augmentation clip lists are duplicated by
# `augmentation_rounds`, but compute_features_from_generator is passed
# n_total=len(os.listdir(<clip dir>)) — the *undoubled* count — so the
# generator is truncated back to one round and the setting silently does
# nothing. Size n_total from the duplicated list instead.
RUN cd /opt/openwakeword/openwakeword && \
    sed -i \
      -e 's/n_total=len(os.listdir(positive_train_output_dir))/n_total=len(positive_clips_train)/' \
      -e 's/n_total=len(os.listdir(negative_train_output_dir))/n_total=len(negative_clips_train)/' \
      -e 's/n_total=len(os.listdir(positive_test_output_dir))/n_total=len(positive_clips_test)/' \
      -e 's/n_total=len(os.listdir(negative_test_output_dir))/n_total=len(negative_clips_test)/' \
      train.py && \
    test "$(grep -c 'n_total=len(\(positive\|negative\)_clips_\(train\|test\))' train.py)" = 4 \
      && echo "augmentation_rounds patch applied (4 sites)"

COPY scripts/download_data.py /opt/scripts/download_data.py
COPY scripts/run_stage.sh /usr/local/bin/stage
RUN chmod +x /usr/local/bin/stage

WORKDIR /work
ENTRYPOINT ["stage"]
CMD ["all"]
