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
