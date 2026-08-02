# Wake

How Neon decides she is being spoken to: the openWakeWord model that owns
waking, Apple's recognizer as a secondary signal, thresholds, and the
mechanics that carry the wake utterance into the session.

Training the model itself is [../wake/README.md](../wake/README.md).

- The wake-model training pipeline lives in `wake/` (moved into the repo
  August 1, 2026, from `~/Downloads/hey-neon`; the ~20 GB of corpora followed
  on August 2, so the pipeline and everything it consumes are one inspectable
  place): an Apple Container (linux/arm64, CPU-only) port of openWakeWord's
  `automatic_model_training` notebook, plus `wake/models/hey_neon.onnx` — the
  weights Neon actually loads. `wake/README.md` documents the stages and, more
  importantly, six upstream bugs this pipeline works around (arm64 dependency
  swaps, the wrong piper-sample-generator fork, `augmentation_rounds` being a
  silent no-op, the built-in TFLite conversion always failing, the Piper
  generation loop leaking memory and getting OOM-killed past ~18k clips, and
  training needing `--shm-size 4g`) so they are not rediscovered. It closes
  with "things that quietly ruin a wake word model" — measured failure modes
  that each looked fine until checked.
  `data/`, `output/`, and `logs/` are gitignored. The pattern is `data/*` with
  a `!data/README.md` negation rather than `data/`, because git will not
  descend into an ignored directory and a negation under it never matches;
  that README documents what belongs in `data/`. Everything under `data/` is
  re-downloadable except `data/my_voice/` — Nick's 50 positive and 33 negative
  recordings, which are not reproducible and are the highest-value asset in
  the directory.
- Wake models ship in the app bundle, not `~/.config/neon/oww/` (changed
  August 1, 2026 while setting up a second machine). They are build artifacts
  locked to the pipeline constants in `OpenWakeListener`, so a per-machine
  copy was an install step pretending to be configuration — and a silent way
  for a model and the code reading it to drift apart. `wake/models/*.onnx`
  (wake model plus the two shared feature extractors) is copied into
  `Neon.app/Contents/Resources/oww/` by `build.sh`.
  `OpenWakeListener.modelDir` resolves the bundle first, then walks up from
  cwd for `wake/models` — the dev fallback exists because the `NEON_OWW_TEST`
  harness runs the bare binary out of `.build/`, where there is no bundle.
  `main.swift` asks the same property for the SFSpeech handoff rather than
  rebuilding the path (it had its own copy, which would have kept SFSpeech
  armed on a fresh clone). Missing models still degrade cleanly to the
  SFSpeech wake path.
- So a fresh clone now needs only `~/.config/neon/secrets.env` and
  `profile.md`, which correctly stay out of git. Everything else is
  `git clone` + `eyes/rebuild.sh`.
- Wake-word findings from live testing: Apple's recognizer sometimes fuses
  the phrase into one token — observed "Hey Neon" → "Henon" — so the matcher
  accepts merged forms too. `dbg()` breadcrumbs (raw stderr) log every
  partial transcript; NSLog alone proved unreliable to observe. Debug
  workflow: run `eyes/Neon.app/Contents/MacOS/Neon 2> /tmp/log` directly —
  Terminal holds a mic grant, so permissions work from a shell launch.
- Wake redesign (after kitchen testing showed "hey neon" only matched when
  spoken with a deliberate pause): the trigger is now the *name at the start
  of an utterance* — silence, then "neon" (hey optional), optionally followed
  by words. Utterance boundaries come from wall-clock gaps between recognizer
  partials (>0.7 s), since on-device segment timestamps are unreliable. Words
  after the name are captured until 0.85 s of trailing silence (6 s cap) and
  sent as the opening user turn — "Neon, set a timer" skips the greeting
  round trip. A mid-sentence "neon" mention does not wake her. Two hardening
  rounds from kitchen testing: (1) the recognizer's own end-of-utterance
  ("no speech detected" error / isFinal) must evaluate a pending wake, not
  restart past it — it usually beats the 0.85 s trailing-silence poll; and
  (2) the recognizer *revises* transcripts rather than only appending
  (observed: junk like "no" replaced wholesale by "Neon what's up"), so the
  utterance start is the common prefix against a baseline snapshot from the
  last silence boundary, recomputed at fire time — never a latched word
  index. The logic lives in a simulation harness (11 scenarios) kept in
  sync by hand; the matcher waits the trailing silence even for a bare
  "Neon", so wake feels ~1 s slower but starts with intent.
- "Hey/ok + neon" (or a fused "henon") wakes from *anywhere* in the current
  utterance — an explicit summons needs no utterance-boundary anchoring;
  bare "neon" stays start-anchored so mentions don't wake her.
- Wake-command mechanics: `AudioRing` keeps the last ~20 s of mic audio
  (16 kHz mono int16); on a wake-with-command, the utterance's *actual
  audio* (from ~1.5 s before its first recognizer partial, capped at 12 s)
  is flushed into the Gemini session instead of Apple's transcript — Gemini
  hears the real thing, tone and all. Faster-than-realtime flush is fine
  with server VAD (`voice/gemini-fastflush-test.mjs`: 3 s flushed
  instantly, clean transcription + reply). The flush happens before
  startAudio() so live mic chunks can't interleave into the past. Apple's
  text is still used for the conversation log and the overlay, and remains
  the fallback (`NEON_WAKE_AUDIO=0`, non-16 kHz engines, bare-name wakes,
  which still get the text greeting instruction). Driven by mic RMS from the session
  (~10 Hz, echo-cancelled so Neon's own voice doesn't trigger it) and by
  wake-listener partials while idle. The same RMS signal guards the idle
  timer — input transcription arrives in a clump when the model responds,
  not while Nick talks, so mic energy is the only live "he's mid-sentence"
  signal (this once put her to sleep mid-question).
- Pre-wake: the instant the matcher spots the name (`onNameHeard`), the
  eyes open and listen while the speaker finishes — no Gemini connection
  yet. The utterance end then opens the session with the captured command;
  if the name candidate dies in a transcript revision (`onWakeAborted`),
  the eyes simply close again, so the pre-wake state always resolves.
- The wake listener runs continuously, including during voice sessions —
  AudioHub fans the mic to both consumers and AEC keeps Neon's own voice
  out of recognition. This removes the recognition-restart dead zone right
  after a session closes, so saying "Neon" works mid-doze, until (and
  after) the eyes fully close. Pre-wake/abort cues are suppressed while a
  session is active.
- openWakeWord runs in-process alongside the SFSpeech matcher
  (`OpenWakeListener.swift`, ONNX Runtime via Microsoft's SwiftPM package —
  the only external dependency; module `OnnxRuntimeBindings`). Models in
  `wake/models/`, bundled at build: melspectrogram.onnx + embedding_model.onnx
  (shared feature extractors from the openWakeWord v0.5.1 release) plus any
  other .onnx as the wake model. A file with "neon" in the name always wins, so
  the retired `hey_jarvis_v0.1` trial model can sit in the directory
  without silently taking over (the loader logs which it ignored).
  `hey_neon.onnx` is now **v4** (2026-08-02) and essentially matches
  openWakeWord's pretrained hey_jarvis on Nick's voice: mean 0.989 against
  jarvis's 0.994, 100% detection on held-out recordings.
  **`layer_size` was the whole story.** v3 and v4 were trained on byte-identical
  features; the only change was 32 → 192. openWakeWord's example config calls 32
  a good default, but their own published model has 316,738 parameters where 32
  yields 50,401 — and that one line was worth more than the speaker-collapse
  fix, the trimming fix and 50 real recordings combined (v1 0.478 mean → v3
  0.597 → v4 0.989). Suspect capacity first on any future phrase.
  **Measure through this pipeline, not the training one.** `verify_model.py`
  uses openWakeWord's Python `predict_clip`, which starts from zero-primed
  buffers, and zeros make any speech score high while they drain — on v3 it
  claimed 91.7% where this listener scored 58.3%. Numbers here come from
  `wake/scripts/eval_runtime.py`, which pushes held-out audio through the real
  Swift path with a 4 s noise lead-in (a bare short clip also under-scores,
  because the phrase never fills the embedding window). The A/B that settled
  it: 20 recordings of "hey jarvis" in the same room through the same recorder
  (`./record.sh jarvis`, kept in `wake/data/ab_jarvis/`) scored 0.994 on the
  pretrained model while v3 scored 0.55 on "hey neon" — proving the runtime and
  the measurement were sound and the model was the weak part.
  v4 separates cleanly: true positives 0.968–0.998, ordinary speech ≤0.018.
  Threshold is therefore not a recall/false-accept trade — anything from 0.1 to
  0.95 detects 100%. It only sets tolerance for deliberate near-misses ("hey
  leon", "hey neo"), the only negatives landing near the positives (0.788,
  0.948, 0.990). `NEON_OWW_THRESHOLD` defaults to **0.2**, arrived at by
  0.8 → 0.4 → 0.2 as live evidence accumulated in `wake-scores.log`. Recorded
  clips carry none of the reverb, distance, or AEC-processed mic path that the
  kitchen does, and **the room disagrees with the eval set**: three clear
  utterances in a quiet room peaked 0.99, 0.94 and **0.29** (that last one
  silently failing at 0.4). It is the *spread* a threshold has to survive, and
  no recorded set shows it — the same class of error as trusting
  `verify_model.py` over `eval_runtime.py`, one layer further out. Lowering
  stays near-free: a 36-utterance negative battery (3 `say` voices, incl. "the
  neon sign in the window is broken" and "hey Leon") tops out at 0.004 for
  ordinary speech, ~50x under the bar. The only negatives that cross 0.2 are
  "hey Nia" and "hey Neo" — deliberate soundalikes that already cleared 0.8,
  so lowering admits no new *kind* of false accept, just more of two
  confusions worth waking on anyway.
- Scoring is **not deterministic**: `primeBuffers()` seeds the pipeline with
  random noise, so the same clip re-scored moves — stable at the extremes
  (a positive held 0.997/0.994/0.993) but wild in the middle ("hey Neo" went
  0.833 → 0.409 between runs). Never conclude anything from a single score
  near the bar, and expect some of the live spread above to be this rather
  than the room.
  **Re-tune whenever the model changes** — 0.35 suited v1, 0.4 suited v3, and
  neither meant anything for v4. Scores above 0.15 that don't fire are logged
  as "near miss" events (max one a second); reading those from the room is how
  you tell a threshold problem from a model problem. Every score ≥0.05, fired
  or not, also appends to `~/.config/neon/wake-scores.log` (timestamp, score,
  outcome, threshold in force, model; tail-trimmed at 1 MB). Outcome is
  WAKE / **held** (over the bar but inside the 2 s refractory window after a
  fire) / miss — only `miss` lines are evidence about the threshold, since the
  tail of a successful wake otherwise reads as a stack of failures. The page's
  event log dies with the app, and a threshold deserves a distribution rather
  than a remembered number. Caveat throughout: 12 positives and 8 negatives
  means one clip moves detection 8 points and false-accepts 12.5, so directions
  are reliable and precision is not — more holdout recordings are the cheapest
  way to sharpen every number here. Pipeline
  details that MATTER (each was a debugged failure): melspectrogram needs a
  480-sample lookback carried across 1280-sample chunks (keep the last 8
  frames per chunk) or the phrase pattern is shredded at seams; buffers
  must be primed with ~4 s of random noise, NOT zeros — zero priming makes
  any speech score ~0.99 while it drains; skip the first few scores after
  priming. mel transform is x/10+2; embeddings are 76-frame windows stride
  8; wake model scores the last 16. Offline harness:
  `NEON_OWW_TEST=file16k.wav .build/release/NeonShell` prints scores —
  validated 0.998+ on three `say` voices, 0.00–0.01 on negatives incl.
  "Hey there John". On detection the session opens with ring audio from
  2 s before the phrase (`preludeFrom`), so the model hears the summons
  and whatever follows, with no gap during connect.
- The wake-path handoff is automatic: when any .onnx whose name contains
  "neon" is in the bundled model directory, SFSpeech stops triggering wakes
  (NEON_SFWAKE=1 re-arms it for debugging) and openWakeWord owns waking.
  SFSpeech keeps running regardless for transcripts, the overlay, voice
  activity, and the pre-wake eye cue. First-turn latency largely solves
  itself in this architecture: detection fires at the end of the phrase,
  so connect+setup overlaps the speaker's question instead of following
  the 0.85 s trailing-silence wait (the SFSpeech path's serial chain was
  ~2-2.7 s after last word vs ~1-1.5 s on warm turns). The debug overlay
  (D) has a `wake` row while idle — active model, last detection score and
  age, and whether SFSpeech is still armed — so "is my model live?" is
  answerable without reading stderr (`dbg()` writes to stderr, which is
  invisible when launched via `open`).
