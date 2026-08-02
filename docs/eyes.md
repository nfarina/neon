# Eyes

The face and the shell around it: the canvas renderer and its animation
channels, emotes, keyboard shortcuts, overlays, kiosk behaviour, and the
build scripts. The first ambient-assistant implementation, under `eyes/`.

- The `emote` tool animates feelings in the eyes: happy, laugh, surprised,
  wink, sad, confused, eyeroll, excited, love (pink hue shift). Declared
  with an enum parameter (schema validated by probe; args arrive in
  `toolCall.functionCalls[].args`). Per-eye wink channels (S.winkL/R) and a
  hue-offset channel (S.hueX) back it; wake/drowse/sleep call clearEmote()
  so a cancelled mid-emote can't strand a closed eye. The prompt encourages
  frequent, unannounced use. X key cycles all emotes with the badge.
- **Emotes must act on shape, not brightness.** The first set mostly pushed
  `open` and `lum`, and Nick found them all too subtle except `confused` —
  which works precisely because it changes the *silhouette* (one lid at half,
  gaze off-axis, held ~2 s). Brightness and openness are already busy carrying
  speaking, hearing and breathing, so an emote spending them is competing with
  background noise. Shape channels added for this: `brow` (−1 outer-down/sad
  .. +1 inner-down/stern, clipped as a slanted wedge off the top — with no
  eyebrows to draw, the upper lid's angle *is* the expression), `curve`
  (0..1, subtracts a rising circle to make ^^ crescents, even-odd clip),
  `pop` (uniform scale) and per-eye `offL`/`offR` (bounce, asymmetry). Hold a
  shape ~1.5 s: a fast flicker reads as a rendering glitch, not a feeling.
  `confused` is deliberately left untouched.
- Listening look: `neon.hearing(amp)` widens the eyes slightly, lifts the
  glow with the speaker's voice level, and holds an attentive near-center
  gaze (saccades stop wandering). Two louder cues were tried and retired: a
  head tilt ("neat but not right") and a screen-edge glow rim — the rim was
  driven by recognizer partials, which lag speech too much to read as live.
  Open eyes now carry "I'm listening" on their own.
- Keys: Esc quit · W wake · S sleep now · D debug overlay · L event log ·
  E cycle engine · T ghost mode (transparent window/canvas so the eyes
  float over the desktop — for watching Claude Code work underneath) · P
  cycle state previews (awake → hearing → thinking → speaking → off, an
  on-screen badge names each; works in plain Chrome too) · Tab (hold)
  shortcut legend.
- The mouse cursor is hidden whenever Neon is frontmost and opaque
  (`NSCursor.hide()` on activate, unhide on resign — they are a balanced pair,
  and an unmatched hide leaves the cursor invisible system-wide until the
  process dies). The page's `cursor: none` is not enough: it only applies
  while the pointer is over web content, so the native arrow reappears on any
  movement. Ghost mode (T) deliberately restores the cursor — the whole point
  there is working with what's underneath.
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
- The snapshot harness must sit **above** Neon's kiosk window, not merely
  `.floating`. macOS throttles requestAnimationFrame in an occluded window to
  nothing — measured 1 frame in 2.6 s under the fullscreen kiosk versus 165
  with it quit — which yields a blank canvas and an animation frozen on its
  first frame, looking exactly like a rendering bug in the page. `shot.swift`
  now sits at `mainMenu + 2` and prints a frame count with every shot, so the
  next occurrence is self-diagnosing.
- `eyes/shot.swift` — `swift eyes/shot.swift out.png [emote ...]` renders a
  contact sheet of the eyes' expressions from an offscreen WKWebView, driving
  the same `window.neon` API the shell uses and snapshotting each at its peak
  frame. Built because checking nine expressions through Chrome is nine round
  trips, and because a fullscreen kiosk window sits on top of Chrome's MCP
  approval dialog. Its window is deliberately on screen (faint, floating):
  macOS throttles requestAnimationFrame in occluded windows, which stalls the
  animation and snapshots the wrong frame.
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
