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
  forever awaiting an invisible permission callback. `build.sh` uses the
  certificate and falls back to ad-hoc with a warning.
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
  `do_call:go_to_sleep{}` in the output transcription — instead of emitting a
  real `toolCall`. VoiceSession treats that transcript leak as the call
  (fallback in the `.outputText` handler), and the system prompt forbids
  speaking tool names aloud.
- Wake redesign (after kitchen testing showed "hey neon" only matched when
  spoken with a deliberate pause): the trigger is now the *name at the start
  of an utterance* — silence, then "neon" (hey optional), optionally followed
  by words. Utterance boundaries come from wall-clock gaps between recognizer
  partials (>0.7 s), since on-device segment timestamps are unreliable. Words
  after the name are captured until 0.85 s of trailing silence (6 s cap) and
  sent as the opening user turn — "Neon, set a timer" skips the greeting
  round trip. A mid-sentence "neon" mention does not wake her. The logic is
  simulation-tested in a scratch harness (8 scenarios); note the matcher
  waits the trailing silence even for a bare "Neon", so wake feels ~1 s
  slower but starts with intent.
- The echo canceller eats the Mac's own speaker output: `say`-based
  self-talk tests are impossible with voice processing on — the wake
  listener literally cannot hear the Mac's own voice (this is why barge-in
  works). Acoustic wake testing requires a human in the room.
- `NEON_GREETING` overrides the synthetic first turn — used with
  `NEON_AUTOWAKE=1` to solo-test behaviors (e.g. a natural goodbye greeting
  verifies the whole tool-sleep path without speaking).
- Next: camera frames into the live session (Gemini supports 1 FPS video);
  more tools (Nick has ideas queued); Claude Code handoff for long tasks;
  wake-phrase accuracy (fast "heyneon" often misses — watch the overlay's
  "mac hears" line; Porcupine remains the fallback plan).

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
  WKWebView that renders the page. Esc quits, W forces a wake.
- `eyes/shell/Sources/NeonShell/WakeWordListener.swift` — wake-word detection
  by continuous on-device `SFSpeechRecognizer` transcription, fuzzy-matched
  for "hey neon" and common mis-hearings. Sessions restart on errors, wake
  triggers, and a 45 s rollover. Deliberately the simplest thing that works;
  if accuracy disappoints, replace this one class with a real wake-word engine
  (e.g. Picovoice Porcupine — requires a free account) — the only contract is
  the `onWake` closure.
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
