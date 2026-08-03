# Voice

The spoken-conversation layer: realtime speech-to-speech engines, the
session lifecycle, tools, costs, memory, and personality. Probes live in
`voice/`; the implementation is `eyes/shell/Sources/NeonShell/VoiceSession.swift`
and `VoiceEngine.swift`.

Wake-word detection is [wake.md](wake.md); the renderer is [eyes.md](eyes.md).

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
- **A captured photo must arrive as its own completed user turn, not as
  `realtimeInput.video`.** Sending the frame alongside the tool response loses
  a race — the tool response starts generation and the frame lands after — so
  she answers from the system prompt instead of the picture. In the kitchen
  that looked like her describing the kitchen while the camera pointed at the
  porch, then getting it right the instant she was asked "are you sure?".
  `voice/gemini-image-order-test.mjs` tested four orderings against the same
  model with an image reading PURPLE GIRAFFE 7 and a prompt insisting she lives
  in a kitchen: `realtimeInput.video` answered blind ("a person's face and a
  bookshelf" — neither present), `turnComplete:false` truncated the reply, and
  answering the tool with "the photo is coming in the very next message, say
  nothing until you have seen it" followed by the image as its own turn read
  the text back correctly. That ordering also comes back *empty* on the
  tool-response turn, so nothing wrong is spoken while the image is in flight.
- Camera note: both Gemini engines accept 1 FPS video frames via
  `realtimeInput.video`, so the camera work is not gated on the 3.1-vs-2.5
  choice.
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
- Personality lives in the VoiceSession system prompt. Nick reduced it to
  "Samantha from the movie Her" — a reference does more than a paragraph of
  adjectives here, since the model already knows the character. Never
  sycophantic or theatrical, no catchphrases (and still no Valorant).
- Assistant tics are prompted *out* explicitly: no "anything else I can help
  with?", no offering further assistance, no recapping the answer just given,
  and no questions asked merely to keep the turn alive. The goal is talking
  like a person, and a person is allowed to finish. This also matters
  mechanically — every trailing offer restarts the 7 s idle clock and drags
  out a conversation that was over. The bare-name wake greeting follows the
  same rule ("say hi in a word or two and leave it there") rather than the
  old "ask what he needs".
- Household facts (names, ages, interests) live OUTSIDE the repo in
  `~/.config/neon/profile.md`, loaded into the system prompt each session —
  edit that file to teach her about people; keep personal data out of git.
- Short-term memory: `ConversationLog` appends each session's transcript
  (from the input/output transcription events) to
  `~/.config/neon/conversations.md`, capped at 30k chars; the last ~2.5k
  chars are injected into every new session's system prompt. Verified
  cross-session: "the magic number is 47" recalled after a sleep/wake
  cycle. Long-term memory (summarization, Claude Code involvement) is
  future work.
