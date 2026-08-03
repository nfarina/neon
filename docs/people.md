# People

Who Neon is talking to. `PersonStore.swift` holds the identities;
`VoiceID.swift` + `Fbank.swift` recognize voices; `FaceID.swift` recognizes
faces; `Enrollment.swift` is the one sitting that captures both.

## Two signals, one question

Voice and face answer the same question and fail in different conditions:
voice works in the dark and across the room, faces work when someone is silent
or when two voices are too alike. Identical twins are exactly why the second
signal exists — Sam and Alex may be hard to separate by voice and easy by
face.

One record per person in `~/.config/neon/people.json` (migrated automatically
from the older `voices.json`), outside the repo. **Enrollment images are never
written to disk**: embeddings are computed from frames in memory and the frames
are dropped. There is no reason to keep a library of photographs of somebody's
children.

## Faces

Apple's Vision has **no public face-identity API** — `VNGenerateFaceprintRequest`
is private, and `VNGenerateImageFeaturePrintRequest` is a general image
descriptor keyed on lighting and background as much as identity, which is
precisely wrong for twins. So:

- **Vision** does detection, landmarks and a capture-quality score (free,
  on-device, very good).
- **ArcFace** (`buffalo_s`, 13 MB, `~/.config/neon/faceid/`) does the 512-dim
  embedding — the same ONNX pattern as the wake word and voice.

Alignment is the part that silently ruins everything: ArcFace embeds a 112×112
crop warped onto a canonical 5-point layout (eyes, nose, mouth corners), and an
unaligned crop still yields 512 confident-looking numbers that match nothing.
The warp is the least-squares *similarity* transform, which has a closed form
in complex arithmetic — `a = Σ(conj(xᵢ)·yᵢ)/Σ|xᵢ|²` over centered points — so no
SVD is needed and a face can never be mirrored.

Vision reports landmarks normalized to the face box in a bottom-left origin;
both have to be undone to get image pixels.

### Checking it without enrolling anyone

```sh
NEON_FACEID_TEST=1 eyes/Neon.app/Contents/MacOS/Neon
```

Six seconds of camera, then frame-to-frame similarity for the *same* face.
That is the real test of the chain: detection, landmarks, alignment and
embedding all have to be right for one face to land in the same place twice.
Expect a mean above ~0.75; scattered values mean alignment is off, not that the
model is bad. First real run: 5/5 faces, mean 0.841 (min 0.689, max 0.952).

That same run exposed a quiet bug worth knowing about: capture quality came
back `min 0.50 mean 0.50 max 0.50` — every frame scoring the fallback constant,
because **`VNDetectFaceLandmarksRequest` never populates `faceCaptureQuality`**.
It needs its own `VNDetectFaceCaptureQualityRequest`, fed the landmark
observations via `inputFaceObservations` so it scores the same faces instead of
re-detecting. Until that was fixed, "keep the best six frames by quality" was
keeping an arbitrary six. A metric with no variance at all is the tell.

Enrollment also runs the camera at 4 fps rather than the session's 1 fps
(`CameraFeed.interval`) — choosing six frames from five is not a choice, and
enrollment frames never leave the machine so there is no token cost to them.

## Watching it work

Every identity judgment appears in the event log (**L**) under its own `who`
kind, in two halves: the hedge Neon actually hears, then the numbers behind it.

```
who  voice: sounds like Nick · Nick 0.71, margin 0.19
who  face: looks like Nick · Nick 0.68, margin 0.31, quality 0.83
who  face: looks like Sam or Alex — too close to tell · Sam 0.55, margin 0.03 (ambiguous)
```

The phrase is what she gets; the numbers are how you decide whether to trust
it. **Margin matters more than score** — a 0.55 that beats the runner-up by
0.03 is a coin flip, and gets reported as ambiguous rather than picked.

The debug overlay (**D**) carries the latest judgment on a `who` row, since the
log scrolls and "who does she think this is right now" is a standing question.

## Voices

`VoiceID.swift` (speaker embeddings) + `Fbank.swift` (the features they eat).

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
from 20 Hz to Nyquist, natural log, then cepstral mean normalization (CAM++
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

One sitting per person, both modalities. The ordinary way is **Settings →
People → enroll** (`,` opens settings), which runs the same sitting with a
mirrored live camera preview — worth more than it sounds, since "look at the
camera for eight seconds" without seeing yourself is how you end up with six
excellent embeddings of your ear.

The terminal path is unchanged and still the one to use when something is wrong
and you want the numbers in a scrollback buffer:

```sh
NEON_ENROL=Sam eyes/Neon.app/Contents/MacOS/Neon
```

Both drive `EnrollmentSession`, which is timer-based rather than a blocking
loop — the panel would otherwise freeze the UI showing its own countdown.

Eight seconds looking at the camera (move your head a little — a few angles
beat one perfect shot; the best six frames by Vision's quality score are kept),
then twelve seconds of natural speech **standing where that person normally
stands**. An embedding built from a phone held to the mouth will not match
far-field, echo-cancelled kitchen audio.

It finishes by printing similarity against everyone already enrolled, per
modality:

```
similarity to the others — lower is better:
  who         voice    face
  Alex       +0.812   +0.204
```

That table is the point of doing both together: it tells you whether a pair
separates by voice, by face, or only by both at once.

From files (16 kHz mono WAV), for the offline harness:

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
- **nothing at all** when nobody matches

The prompt tells her to use it the way a person uses recognizing a voice: greet
them by name if it fits, keep it to herself otherwise, and drop it if what they
say contradicts it. It also says outright that identity is **never** a reason
to withhold anything, verify anyone, or treat a request as suspicious.

That last sentence was earned. The no-match case used to be phrased "doesn't
sound like anyone you know", and Neon — handed a sentence about a stranger —
refused Nick his own household details on the strength of it. Nobody asked for
an access check; the model inferred one from the framing. So the no-match case
now says *nothing*, and she behaves exactly as she did before recognition
existed. This is a warmth feature, not a security feature, and a household
assistant that can gate on a 0.55 cosine similarity is a worse assistant than
one that can't.

Mid-session re-identification is not wired yet — it needs per-utterance
segmentation, and the wake utterance covers most of the value.
