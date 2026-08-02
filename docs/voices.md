# Voices

Who is talking. `VoiceID.swift` (speaker embeddings) + `Fbank.swift` (the
features they eat).

## How it works

A speaker-embedding model turns a few seconds of speech into a 192-dimensional
vector. Each enrolled person is the mean of their clips; a live utterance is
whoever it is nearest to by cosine similarity, if it clears the threshold.

Model: **3D-Speaker CAM++** (`campplus.onnx`, 27 MB), from the sherpa-onnx
release collection. It lives in `~/.config/neon/voiceid/` — *not* in
`wake/models/`, where `OpenWakeListener` would take any unrecognised `.onnx` as
a candidate wake model — and not in git, since it is a third-party download
rather than a build artifact.

Voiceprints go in `~/.config/neon/voices.json`, outside the repo. They are
biometric data about a family including two children; same rule as the
household profile.

## Features are the fiddly part

These models take Kaldi-style 80-bin log-mel filterbank features, not waveform:
sherpa-onnx and friends do that step outside the ONNX graph, so a Swift host
has to as well. `Fbank.swift` implements it — 25 ms frames, 10 ms hop, Povey
window, pre-emphasis 0.97, DC removal, 512-point FFT, 80 triangular mel filters
from 20 Hz to Nyquist, natural log, then cepstral mean normalisation (CAM++
ships `feature_normalize_type: mean`).

Those constants are not knobs. Get one wrong and you still get 192 numbers that
look like an embedding and match nothing — which is why the validation below
matters more than usual.

openWakeWord's `melspectrogram.onnx` cannot be reused: 32 bins, its own
scaling, a different window. Different feature space entirely.

## Validated

Five macOS voices, enrolled on two clips each, tested on three *held-out*
sentences each:

```
threshold 0.55   clip → samantha  daniel  karen  fred  flo
  daniel-1.wav   +0.245  +0.926  +0.310  +0.092  +0.107  → daniel ✓ (margin 0.616)
  flo-2.wav      +0.164  +0.051  +0.056  +0.736  +0.929  → flo ✓ (margin 0.193)
  karen-3.wav    +0.565  +0.290  +0.851  +0.053  +0.054  → karen ✓ (margin 0.286)
  ...
15/15 correct, mean margin 0.336, worst 0.193
```

A first run scored 9/12 with three "errors" that were all the same clip pair
scoring *identically* — `say -v Alex` had silently fallen back to Samantha
because Alex isn't installed, so two "different people" were byte-identical
audio. Worth remembering as a debugging shape: identical columns mean identical
input, not a broken model. (It was also an accidental preview of the twins
case: two indistinguishable voices produce margin 0.000.)

Note `fred` vs `flo` — both classic formant-synthesis voices, and the closest
pair at ~0.72 cross-similarity against ~0.94 self-similarity. Similar voices
from the same "family" still separate, with a thinner margin. That is the shape
to expect from Sam and Alex.

## Enrolling

From the live microphone, which is what you want — an embedding built from a
phone held to the mouth will not match far-field, echo-cancelled kitchen audio:

```sh
NEON_VOICEID_RECORD=Sam eyes/Neon.app/Contents/MacOS/Neon
```

12 seconds of natural speech, standing where that person normally stands. It
splits the recording into thirds and averages three embeddings, then prints
similarity against everyone already enrolled — watch that number for the twins.

From files (16 kHz mono WAV):

```sh
NEON_VOICEID_ENROL="Nick=a.wav,b.wav" eyes/Neon.app/Contents/MacOS/Neon
```

Re-enrolling replaces rather than blends: children's voices drift, and half a
stale voiceprint is worse than none.

## Checking separability

```sh
NEON_VOICEID_TEST=/path/to/clips eyes/Neon.app/Contents/MacOS/Neon
```

Scores every WAV in a directory against every enrolled voice (a clip named
`sam-2.wav` is assumed to be Sam) and prints the matrix, accuracy, and
margins. **The margin is the number that matters**, not the accuracy: picking
right by 0.02 is a coin flip in a noisier room.

`NEON_VOICEID_THRESHOLD` overrides the 0.55 cutoff.

## How Neon uses it

At wake, the utterance that woke her is scored (~28 ms, against a socket
connect of roughly a second, so it resolves *before* the session opens rather
than arriving a turn late). The result goes into the system prompt as a hedge,
never an assertion — Nick's call, and the right one: this is a guess from a few
seconds of far-field audio, and confidently using the wrong name is worse than
not knowing.

- `sounds like Nick`
- `sounds like Sam or Alex — too close to tell` (top two within 0.06)
- `doesn't sound like anyone you know`

The prompt tells her to use it the way a person uses recognising a voice: greet
them by name if it fits, keep it to herself otherwise, never announce that she
identified anyone, and drop it if what they say contradicts it.

Mid-session re-identification is not wired yet — it needs per-utterance
segmentation, and the wake utterance covers most of the value.
