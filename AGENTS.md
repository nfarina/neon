# Neon

## Purpose of This File

This file is durable project memory for AI agents working on Neon. Its expected
reader is an AI, not a human.

It records facts, decisions, current intentions, and unresolved ideas that are
useful when starting a new session. It is not a place for generic engineering
advice, safety boilerplate, workflow rules, or explanations of things a capable
agent already knows. Add project-specific context; do not turn it into a
general-purpose agent handbook.

## Identity and Mission

Neon is Nick's personal AI assistant and the project used to build that
assistant. Neon lives on a dedicated MacBook in Nick's kitchen.

The long-term idea is an assistant that is conversational, has access to useful
personal context, can take actions on Nick's behalf, and can participate in
improving its own implementation. The development machine and the machine
running Neon are the same computer.

## Why It Is a Mac

Useful personal context is in Apple's ecosystem, including Messages, Calendar,
Reminders, Contacts, Mail, iCloud data, and native Mac applications. Many of
these do not have suitable public APIs. A Mac signed into Nick's accounts can
access or automate them locally through native applications, macOS automation,
and command-line utilities.

Nick's primary MacBook Air remains the machine for his other applications,
side projects, and general development. The MacBook Neon is dedicated to
developing and running Neon.

## Project Location

All Neon source code and project documentation live under:

```text
/Users/nick/Code/neon
```

Platform-installed applications, user preferences, credentials, and runtime
data can remain in their normal macOS locations. They are not project source.
Credentials and private personal data are not stored in this repository.

## Ambient Assistant Vision

The likely first project is a full-screen ambient application for the kitchen:

- It renders a simple, expressive pair of eyes.
- The eyes can close or appear asleep while nothing is happening.
- The wake phrase is expected to be "Hey Neon."
- Hearing the wake phrase opens the eyes and begins a spoken interaction.
- A speech API transcribes Nick's request.
- An AI model produces the response.
- Neon responds aloud through speech synthesis.

The initial goal is a drop-in replacement for the current Alexa Plus device:
fast, natural access to an AI with broad world knowledge. Personal tools and
deeper Mac integration can follow.

OpenAI and Grok speech services have been mentioned as possibilities. No
speech-to-text, language-model, text-to-speech, wake-word, application
framework, or visual implementation has been selected.

The eyes and voice loop are the expected first build because they are the most
fun and establish Neon as a presence in the kitchen. This is current intent, not
a finalized implementation plan.

## Remote Agent Vision

Another direction is a long-running Claude Code capability that Nick can reach
from his phone and use for more involved personal-assistant tasks.

Examples discussed:

- Research a topic or website and put useful results on Calendar.
- Inspect a Messages conversation using `imsg` and draft or send a reply.
- Look through email and triage it.
- Run other longer computer-based tasks while Nick is away from the Mac.

One possible interface is a small iOS app invoked with the iPhone's Action
button. Nick would dictate a request; the app would send the transcription to
the Mac; the Mac might start a Claude Code session with the prompt using the
`-p` argument; and a result could return through a notification, email, or some
other channel.

This remote-agent concept is exploratory. The transport, iOS implementation,
session lifecycle, response channel, and degree of autonomy are undecided.

## AI and Development Context

- Claude Code is intended to be the primary AI engine powering Neon.
- Codex is currently helping set up the machine and project.
- Claude, Grok, Codex, and other CLI agents may all work in this directory.
- `CLAUDE.md` points Claude Code to this file so project context has one
  canonical source.
- Neon is meant to be able to improve its own code on the computer where it
  runs.

## Current Machine State

As of July 31, 2026:

- Apple Command Line Tools are installed.
- Homebrew is installed and available for additional tools.
- The full Xcode application is not installed.
- The current preference is to avoid installing full Xcode unless Neon
  eventually requires it.
- `imsg` was installed through Homebrew for local Messages access.
- Node is installed through Homebrew, primarily so `npx`-based MCP servers work.
- The `chrome-devtools` MCP server is configured at user scope in
  `~/.claude.json` as `npx chrome-devtools-mcp@latest --autoConnect`, matching
  the MacBook Air.
- `--autoConnect` attaches to the normal running Chrome rather than a separate
  profile. It needs remote debugging enabled at
  `chrome://inspect/#remote-debugging` *and* the Chrome-side dialog approving
  the incoming debugging connection. Enabling the toggle only opens the port;
  it does not authorize a client.
- If the server reports `Could not find DevToolsActivePort`, that message is
  misleading. The package wraps the port-file read and the WebSocket connect in
  one `try`, so a refused connection is reported as a missing file. Check
  whether the connection was approved in Chrome before suspecting the file.
- `--browserUrl` is not a usable fallback on Chrome 151: the classic
  `/json/version` discovery endpoint returns 404 in this mode.
- The Chrome DevTools skills that ship inside the `chrome-devtools-mcp` package
  are installed in `~/.claude/skills`. `~/.claude-update-chrome-mcp-skills`
  refreshes them from the latest published package; it also lists skills in
  that directory that did not come from the package, so stale ones are visible.
- The source for Nick's `allow-chrome-mcp` helper is tracked at
  `tools/allow-chrome-mcp`. It is installed as the user LaunchAgent
  `com.nfarina.allow-chrome-mcp` and requires macOS Accessibility permission.
- Neon's installed Swift 6.3.3 compiler and default macOS 26.5 SDK are
  mismatched. The `allow-chrome-mcp` Makefile currently builds against the
  installed macOS 15.4 SDK with a macOS 15 deployment target.
- Nick's MacBook Air can be mounted through Finder's Network view for small,
  selective file transfers.
- This directory is a Git repository on the `main` branch.

## Voice Lab

Work toward Neon's spoken conversation lives under `voice/`.

- API keys for OpenAI, Gemini, and xAI are in `~/.config/neon/secrets.env`
  (mode 600, outside the repo). The Gemini key is valid for the AI Studio
  `generativelanguage.googleapis.com` endpoint.
- The current plan is a native speech-to-speech session layer for
  conversation (Gemini Live first — its 1 FPS camera input suits the kitchen
  and it is the cheapest), with Neon's personal Mac tools exposed to the
  session via tool calling, and long tasks handed off to Claude Code.
  OpenAI Realtime and Grok Voice are the A/B alternatives; all three keys
  are on hand.
- `voice/gemini-live-test.mjs` — dependency-free Node harness proving the
  Gemini Live API round trip: WebSocket session, text turn in, 24 kHz PCM
  audio out, played via `afplay`, with output transcription. Usage:
  `node gemini-live-test.mjs [model] [prompt...]`.
- Live-capable model names on this key as of July 31, 2026:
  `gemini-2.5-flash-native-audio-latest` (plus dated previews),
  `gemini-3.1-flash-live-preview`, `gemini-3.5-live-translate-preview`.
  Both tested working; the harness defaults to native-audio-latest.
- Neon's first spoken words (native-audio-latest, July 31, 2026): "Zap!
  Just testing the speakers, Nick. I'm Neon, your new AI assistant. Let's
  get things done, fast!"
- Persona rule: the Valorant naming is a silent partner — an inside joke in
  the project, never part of the assistant's character. System prompts must
  not mention Valorant or push an "electric" persona; Neon should sound
  warm, quick, and natural, with no catchphrases. (The first-words "Zap!"
  came from a prompt that mentioned the namesake; that mention was removed.)
- Audio architecture decision: the Swift shell owns all audio (mic capture,
  playback, and later the camera); the web page is a pure renderer driven
  over the JS bridge (`neon.wake()`, later `neon.speaking(amplitude)`).
  One native audio graph avoids the wake-word listener and voice session
  fighting over the mic and keeps echo cancellation in AVFoundation.
- `voice/gemini-live-audio-test.mjs` — streams a prerecorded 16 kHz WAV as
  fake mic audio to validate the `realtimeInput.audio` schema and server-side
  VAD (speech in, silence, spoken reply out). Verified working.
- `eyes/shell/Sources/NeonShell/VoiceSession.swift` — the real conversation
  loop: wake word (or W key) opens a Gemini Live WebSocket session, streams
  mic audio up at 16 kHz (AVAudioConverter from the tap format), plays 24 kHz
  replies through AVAudioPlayerNode, and enables input voice processing for
  echo cancellation. Server VAD handles turn-taking and barge-in
  (`interrupted` flushes the playback queue). On session open the wake
  listener releases the microphone (`WakeWordListener.stop()`); on close
  (15 s idle, S key, or socket loss) it takes it back. The eyes hold awake
  during the session (`neon.hold`) and pulse with output amplitude
  (`neon.speaking`). On setup the session sends a synthetic turn so Neon
  greets immediately after the wake phrase.
- The full loop worked end to end on July 31, 2026: wake phrase → eyes wake →
  Gemini session → spoken multi-turn conversation → idle → sleep.
- The app is signed with the self-signed "Neon Dev" certificate (login
  keychain; generated files in `~/.config/neon/codesign*`). This matters:
  ad-hoc signing gives each build a new identity, so macOS silently resets
  the Microphone TCC grant on every rebuild and the wake listener hangs
  forever awaiting an invisible permission callback. `build.sh` prefers
  "Neon Dev", then any Apple Development identity (a machine signed into
  Xcode already has one, and it is just as stable — no cert to generate or
  trust), and only then falls back to ad-hoc with a warning.
- The wake-model training pipeline lives in `wake/` (moved into the repo
  August 1, 2026, from `~/Downloads/hey-neon`): an Apple Container
  (linux/arm64, CPU-only) port of openWakeWord's `automatic_model_training`
  notebook, plus `wake/models/hey_neon.onnx` — the v1 weights Neon actually
  loads. `wake/README.md` documents the stages and, importantly, four
  upstream bugs this pipeline works around (arm64 dependency swaps, the wrong
  piper-sample-generator fork, `augmentation_rounds` being a silent no-op, and
  the built-in TFLite conversion always failing) so they are not rediscovered.
  `data/`, `output/`, and `logs/` are gitignored — ~19 GB of corpora, clips,
  and features, all reproducible.
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
- Audio runs through `AudioHub`: one persistent AVAudioEngine shared by the
  wake listener and voice sessions (both are tap consumers), with voice
  processing (echo cancellation) enabled once at startup. Verified working
  full-duplex: Neon's own speech does not appear in input transcription, so
  voice barge-in works. Two conditions, found by bisection, are required
  for VP to initialize (else CoreAudio -10875): tap the input in mono (the
  VP node exposes the raw 4-channel mic array on this MacBook), and attach
  the playback node lazily after the engine is running, never during graph
  construction. VoiceSession falls back to a half-duplex gate (mic muted
  during playback) only if VP is unavailable.
- `NEON_AUTOWAKE=1` in the environment starts a voice session ~2 s after
  launch — full-path testing without speaking the wake phrase.
- Privacy note: the wake listener's continuous transcription is on-device
  only; audio reaches Google only during an open session after the wake
  phrase.
- Multi-engine A/B: `VoiceEngine.swift` abstracts the wire protocol
  (GeminiEngine on `gemini-3.1-flash-live-preview`, OpenAIEngine on
  `gpt-realtime-2.1`); `VoiceSession` is engine-generic. The E key cycles the
  engine for the next session (persisted in UserDefaults `neon.voiceProvider`;
  `NEON_PROVIDER` overrides). The D key toggles a debug overlay (bottom bar,
  1 s refresh) showing engine, session time, token counts, session and
  lifetime cost, and a live transcription line — the wake listener's running
  transcript while idle ("mac hears"), the session's input transcription
  during a call. Lifetime cost persists in `~/.config/neon/usage.json`.
- A/B verdict (July 31, 2026, kitchen testing): OpenAI Realtime sounds great
  but is ~10× Gemini's price ($32/1M audio-in, $64/1M audio-out vs $3/$12) —
  too expensive for this project. **Gemini is the engine for now.** Grok
  Voice (~$0.05–0.08/min) is untested: the xAI team has no credits; buying
  some at console.x.ai unblocks a `wss://api.x.ai/v1/realtime` probe.
- Gemini session config (validated by `voice/gemini-config-test.mjs`): voice
  is Leda (`speechConfig.voiceConfig.prebuiltVoiceConfig`), Gemini 3.x gets
  `thinkingConfig.thinkingLevel: HIGH` (2.5 uses a budget schema instead, so
  the gemini25 engine sends none), and Google Search grounding is on via a
  `googleSearch` tools entry — verified returning genuinely current
  headlines from both models. Idle timeout is 7 s of post-reply silence.
- Idle doesn't hang up abruptly: after the 7 s the session enters a doze
  grace — the eyes run the dozing-off animation while the WebSocket stays
  open, and mic voice energy during it snaps her back awake with the
  conversation intact (`onDoze`). The session actually closes only when the
  doze completes (~5 s). So the contract is: you can keep talking to her
  until her eyes are fully shut.
- Thinking is visible in the stream: with `includeThoughts: true`, thought-
  summary parts (`thought: true`) arrive during the pre-reply pause
  (validated by `voice/gemini-thinking-test.mjs` — ~2.5 s of thoughts before
  first audio on a search question). VoiceSession turns the first thought
  part into `onThinking(true)` and the first audio chunk into
  `onThinking(false)`; the eyes respond with the thinking look
  (`neon.thinking`, blended via an S.think channel): hue drifts from cyan to
  indigo, lids narrow, gaze lifts and slowly scans left-right, and the glow
  pulses — deliberately unmistakable (the first, subtler version read as
  "eyes go a bit more square"). Verified by screenshot via Chrome.
- Tool-sleep closes must wait for *received-audio quiet*, not just an empty
  playback queue: goodbye audio chunks trail the tool call, and the queue can
  momentarily drain mid-stream (this clipped goodbyes in the kitchen). The
  session closes when the queue is empty AND no audio has arrived for 0.7 s
  (12 s cap). Leak formats observed so far: `do_call:go_to_sleep{}` and
  `<go_to_sleep>` — the fallback matches on the tool-name substring.
- Tool calling works (validated by `voice/gemini-tool-test.mjs`; wire shape
  `toolCall.functionCalls[{name, args, id}]`). First tool: `go_to_sleep` —
  declared to both engines; the model calls it when the user says goodbye or
  when it woke by accident to background noise. The session closes after the
  playback queue drains (so a spoken "goodnight" isn't clipped) and the eyes
  close immediately (`neon.sleep()`), skipping the slow dozing animation,
  which is reserved for idle-silence closes. The system prompt pairs every
  goodbye with the tool call — a bare "say goodnight then sleep" instruction
  was not enough for Gemini to call it, but a natural user goodbye is.
- Idle timeout semantics: the 15 s clock is *silence after the assistant
  finished speaking*, not after data arrived — the API delivers reply audio
  much faster than realtime, so the timer is bumped when the playback queue
  drains and never fires while audio is still playing. (Before this fix a
  long answer could hit the idle close mid-playback.)
- Known metering gaps: sessions closed by `go_to_sleep` can miss the final
  `usageMetadata` (logged cost reads low); Gemini's output transcription
  sometimes leaks the literal function-call text (e.g. `do_call:go_to_sleep`)
  into the "saying:" log line. Both cosmetic at current prices.
- Gemini live-preview tool-calling quirk (observed in the kitchen): the model
  sometimes *speaks* the call — literally saying "go to sleep" with
  `do_call:go_to_sleep{}` in the output transcription — instead of (or as
  well as) emitting a real `toolCall`. VoiceSession treats that transcript
  leak as the call (fallback in the `.outputText` handler), and the system
  prompt forbids speaking tool names aloud. This is a known weakness of the
  *native-audio* live architecture (calls are emitted as tokens interleaved
  in the speech stream); half-cascade models are the documented remedy but
  none are available on this key. As an A/B, engine "gemini25"
  (`gemini-2.5-flash-native-audio-latest`, the GA native-audio model) is in
  the E-key cycle — gemini → gemini25 → openai — with same audio rates
  ($3/$12) and cheaper text ($0.50/$2.00). First solo test: clean toolCall,
  no verbalization.
- Camera note: both Gemini engines accept 1 FPS video frames via
  `realtimeInput.video`, so the camera work is not gated on the 3.1-vs-2.5
  choice.
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
- The echo canceller eats the Mac's own speaker output: `say`-based
  self-talk tests are impossible with voice processing on — the wake
  listener literally cannot hear the Mac's own voice (this is why barge-in
  works). Acoustic wake testing requires a human in the room.
- `NEON_GREETING` overrides the synthetic first turn — used with
  `NEON_AUTOWAKE=1` to solo-test behaviors (e.g. a natural goodbye greeting
  verifies the whole tool-sleep path without speaking).
- Camera: `CameraFeed.swift` captures 1 FPS VGA JPEGs while a session is
  open (never otherwise), but frames are only *sent* on a `capture_image`
  tool call — the model looks on demand (frame via `realtimeInput.video` +
  a `toolResponse`), instead of streaming ~250 tokens/frame it rarely
  needed. Verified: asked to look, she called the tool, one frame went up,
  she described the actual scene. OpenAI engine takes no video;
  `NEON_CAMERA=0` disables. First camera use prompts for TCC approval —
  the prompt only shows when the app is launched normally (`open`).
- Latency: `thinkingLevel` is LOW by default — HIGH added a multi-second
  deliberation to every spoken turn; search grounding works at any level.
- Playback truth: `scheduleBuffer` completion uses `.dataPlayedBack` — the
  default `.dataConsumed` fires when the mixer *reads* a buffer, up to a
  chunk before the speaker finishes, which made tool-closes clip goodbyes
  even after waiting for the queue to drain. Tool-close also adds a 0.35 s
  margin after quiet.
- "Hey/ok + neon" (or a fused "henon") wakes from *anywhere* in the current
  utterance — an explicit summons needs no utterance-boundary anchoring;
  bare "neon" stays start-anchored so mentions don't wake her.
- Personality lives in the VoiceSession system prompt: bright, playful,
  opinionated, light banter — but never sycophantic or theatrical, no
  catchphrases (and still no Valorant).
- Household facts (names, ages, interests) live OUTSIDE the repo in
  `~/.config/neon/profile.md`, loaded into the system prompt each session —
  edit that file to teach her about people; keep personal data out of git.
- The `emote` tool animates feelings in the eyes: happy, laugh, surprised,
  wink, sad, confused, eyeroll, excited, love (pink hue shift). Declared
  with an enum parameter (schema validated by probe; args arrive in
  `toolCall.functionCalls[].args`). Per-eye wink channels (S.winkL/R) and a
  hue-offset channel (S.hueX) back it; wake/drowse/sleep call clearEmote()
  so a cancelled mid-emote can't strand a closed eye. The prompt encourages
  frequent, unannounced use. X key cycles all emotes with the badge.
- Short-term memory: `ConversationLog` appends each session's transcript
  (from the input/output transcription events) to
  `~/.config/neon/conversations.md`, capped at 30k chars; the last ~2.5k
  chars are injected into every new session's system prompt. Verified
  cross-session: "the magic number is 47" recalled after a sleep/wake
  cycle. Long-term memory (summarization, Claude Code involvement) is
  future work.
- Listening look: `neon.hearing(amp)` widens the eyes slightly, lifts the
  glow with the speaker's voice level, and holds an attentive near-center
  gaze (saccades stop wandering). Two louder cues were tried and retired: a
  head tilt ("neat but not right") and a screen-edge glow rim — the rim was
  driven by recognizer partials, which lag speech too much to read as live.
  Open eyes now carry "I'm listening" on their own.
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
- Keys: Esc quit · W wake · S sleep now · D debug overlay · L event log ·
  E cycle engine · T ghost mode (transparent window/canvas so the eyes
  float over the desktop — for watching Claude Code work underneath) · P
  cycle state previews (awake → hearing → thinking → speaking → off, an
  on-screen badge names each; works in plain Chrome too) · Tab (hold)
  shortcut legend.
- S means "that's enough for now", not "hang up": it closes the session
  with reason "manual", which the eyes treat exactly like a tool sleep —
  lids shut at once. The slow dozing-off animation stays reserved for
  silence running out, so the animation always tells you *why* she slept.
  With no session live, S just shuts the eyes.
- Event log (L): a right-edge trace of the conversation's machinery —
  session open/ready/close (with cost), wake detections and their scores,
  both sides' transcripts, tool calls and their results, thinking, emotes,
  dozes. `neon.event(kind, text)` appends; kinds (session/you/neon/tool/
  think/emote/wake/sleep/error) are colour-coded. Events accumulate whether
  or not the panel is showing, so L reveals history rather than an empty
  box. Transcripts stream in fragments, so same-kind you/neon lines within
  10 s coalesce into one growing row instead of one row per fragment.
  Strings cross into JS via JSON encoding (`jsString`) — transcripts
  contain quotes and apostrophes constantly.
- The preview is a per-frame override in frame() that pins the renderer to
  the chosen look; "off" returns control to the live mechanics. (The first
  one-shot design froze the page: it referenced draw()'s `t` from frame(),
  and the ReferenceError killed the rAF loop — eyes locked open, all keys
  seemingly dead. A watchdog now also recovers any "waking" state that
  misses its hand-off to "awake".)
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
  `hey_neon.onnx` (first training run, 2026-08-01) is live: 0.92 peak on
  three `say` voices, 0.001 on negatives — a softer peak than jarvis's
  0.998, traced to training on 9 of the 604 available voices and none of
  Nick's own; a retrain is in progress. Detection threshold is
  `NEON_OWW_THRESHOLD` (default 0.35): true positives plateau near the
  model's ceiling while negatives sit at ~0.001, so the headroom below the
  peak is free range at the far end of the kitchen. Scores above 0.15 that
  don't fire are logged as "near miss" events (max one a second) — reading
  those from the room is how you tell a threshold problem from a model
  problem. Pipeline
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
- Next: more tools; Claude Code handoff for long tasks; long-term memory.

## Eyes Proof of Concept

The first ambient-assistant implementation exists under `eyes/`:

- `eyes/web/index.html` — the eyes themselves: a single self-contained HTML
  canvas page. State machine: asleep (glowing slits, breathing sway, rare
  twitches) → waking (overshoot snap-open, settling blink, curious glances) →
  awake (randomized saccades and blinks for ~8 s) → drowsy → asleep.
  `window.neon.wake()` / `window.neon.sleep()` are the external API; Space/W
  wakes and S sleeps when the page has focus.
- `eyes/shell/` — SwiftPM package (`swift build`, no Xcode) providing the
  kiosk shell: borderless fullscreen NSWindow above the menu bar hosting a
  WKWebView that renders the page. Ctrl-Opt-Cmd-Q quits, W forces a wake.
- `eyes/shell/Sources/NeonShell/Kiosk.swift` — unattended-appliance
  lockdown, added when Neon moved to the kitchen counter for live testing.
  The machine stays logged into Nick's account (the rest of the assistant
  needs his iCloud data), so the window being on top is not enough: kiosk
  presentation options close Cmd-Tab, Cmd-Q, Cmd-Opt-Esc and the
  power-button dialog, and Esc no longer quits. `NEON_DEV=1` turns all of it
  off and restores Esc — necessary, because Neon is developed on the machine
  she runs on and `disableProcessSwitching` in a debug run means logging out
  to get the desktop back. Presentation options are dropped whenever the app
  is not active, so they are reapplied in `applicationDidBecomeActive`.
  Known residual gaps: Spotlight's Cmd-Space still opens, and a crash leaves
  the desktop exposed. The Tab legend in the eyes page deliberately omits the
  quit chord — anyone reading that legend is a guest at the counter, and it
  is the one shortcut that leads out of Neon and into Nick's session. Do not
  "helpfully" add it back.
- `eyes/shell/Sources/NeonShell/DisplayKeeper.swift` — keeps the panel lit
  and the session unlocked, and owns deep sleep. An `NSProcessInfo` activity
  assertion (not `pmset`) blocks display and system sleep, so the machine
  behaves normally again the moment Neon exits; a 60 s
  `IOPMAssertionDeclareUserActivity` tick handles the screen saver and lock,
  which run off the HID idle clock that assertions do not touch (this is
  what `caffeinate -u` does). Backlight control goes through
  `DisplayServicesGetBrightness`/`SetBrightness`, dlopened from a private
  framework because the public IOKit brightness API stopped working on Apple
  silicon; both symbols resolve and writes return 0 on this machine, and a
  missing symbol degrades to render-only dimming rather than a launch
  failure. Brightness is restored on quit and on SIGINT/SIGTERM (the debug
  workflow runs the binary from a shell), and a manual brightness change
  during deep sleep is detected and left alone.
- Deep sleep: after `NEON_DEEPSLEEP_SECS` (default 600) with no interaction,
  the eyes fade over 6 s to an ember and the backlight goes to
  `NEON_DEEP_BRIGHTNESS` (default 0.03); the render throttles to 10 fps.
  The shell owns the idle clock and passes the render level to
  `neon.deepSleep(on, level)`, milder when it also controls the backlight so
  the two fades do not multiply into an invisible screen. Wake-listener
  transcripts deliberately do not count as activity — they fire for any
  speech in the room, and dinner across the kitchen should not light the
  display back up. Only a wake, a live session, or the keyboard does.
- `eyes/shell/Sources/NeonShell/WakeWordListener.swift` — wake-word detection
  by continuous on-device `SFSpeechRecognizer` transcription, fuzzy-matched
  for "hey neon" and common mis-hearings. Sessions restart on errors, wake
  triggers, and a 45 s rollover. Deliberately the simplest thing that works;
  if accuracy disappoints, replace this one class with a real wake-word engine
  (e.g. Picovoice Porcupine — requires a free account) — the only contract is
  the `onWake` closure.
- `eyes/rebuild.sh` — build + restart in one command; the everyday loop.
  Both the Swift and `web/index.html` are copied into the bundle, so an
  edit to *either* needs a rebuild, not just a relaunch.
- `eyes/shell/build.sh` — builds and assembles `eyes/Neon.app` by hand
  (Info.plist with mic/speech usage strings, ad-hoc codesign). Run with
  `open eyes/Neon.app`; first launch prompts for Microphone and Speech
  Recognition.
- Rationale for the hybrid: the web page is where animation iteration happens
  (openable in plain Chrome, screenshotable via the Chrome DevTools MCP); the
  native shell owns the screen, the mic, and eventually the whole voice
  pipeline (STT/TTS).

## Current Decisions

- The project is named Neon, after the Valorant agent — Nick names side
  projects after Valorant characters (Sage, Phoenix, Iso, Astra). It was
  renamed from "Neo" on July 31, 2026; "neon" also suits the glowing eyes,
  and it is a dictionary word, which makes wake-word recognition more
  reliable than "Neo" was.
- Neon development stays in `/Users/nick/Code/neon`.
- Unrelated development stays on the MacBook Air.
- The project will favor the existing Command Line Tools and Homebrew setup
  before considering full Xcode.
- The ambient eyes and spoken conversation are the likely first implementation
  target.
- The implementation architecture has not been chosen.
- Agents can commit completed, coherent work without waiting for Nick to make
  the commit or explicitly request one. Unfinished work should not be committed
  merely to make the working tree clean.
- This file stays focused on facts, actual decisions, current intent, and open
  questions rather than generic guidance for AI agents.
