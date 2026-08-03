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

## Where the Details Live

This file is the charter and the index: identity, mission, standing
decisions, and the working agreement. Everything below the line is
implementation knowledge, split out so a session working on one part of Neon
does not carry the other three. Read the file you need; add findings to the
file they belong to.

| File | What is in it |
| --- | --- |
| [docs/voice.md](docs/voice.md) | Realtime speech-to-speech engines, session lifecycle, tools, costs, memory, personality |
| [docs/wake.md](docs/wake.md) | Waking her: openWakeWord, Apple's recognizer, thresholds, wake-utterance capture |
| [docs/eyes.md](docs/eyes.md) | Renderer and animation channels, emotes, shortcuts, overlays, kiosk, build scripts |
| [docs/people.md](docs/people.md) | Telling the family apart by voice and face: embeddings, enrollment, thresholds |
| [docs/memory.md](docs/memory.md) | What she remembers across conversations, and the nightly dreaming pass |
| [docs/plugins.md](docs/plugins.md) | Switchable features, the settings panel, and the JS↔Swift bridge |
| [docs/tasks.md](docs/tasks.md) | The kitchen timer, background tasks, and how each reports back |
| [docs/machine.md](docs/machine.md) | The machine, its tooling, and the permissions that keep breaking |
| [docs/release.md](docs/release.md) | Sparkle, notarization, and cutting a release |
| [wake/README.md](wake/README.md) | Training a wake model end to end (container pipeline) |
| [README.md](README.md) | The public front door — written for a stranger, not for us |

Current state in one paragraph: the ambient eyes and the spoken loop are
built and running in the kitchen. Neon wakes on a locally trained "hey neon"
model, holds a conversation through Gemini Live with grounding and thinking
visible in her face, sees through the camera on request, emotes, remembers
across sessions, recognizes who is talking, reads the family calendar, and
puts herself to sleep. Features she might not be allowed are plugins, switched
on in a settings panel over the eyes. Next: more plugins; long-term memory;
shipping it to anyone who wants one.

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
- **This repository is public** (2026-08-03). Nothing personal goes in it:
  no names, ages, addresses, or household facts, in code, comments, docs or
  example output. All of that lives in `~/.config/neon/`, and the code reads it
  from there. Use invented names in examples. This is a rule about the repo,
  not about Neon — she knows the family perfectly well, from the profile.
- Features somebody might reasonably not want are plugins, off by default
  unless there is a reason otherwise (`docs/plugins.md`). "Off" means the tool
  is never declared to the model, not that it is refused.
- Background tasks via Claude Code are **shelved** — too slow to be part of a
  spoken conversation. Off by default; see `docs/tasks.md`.
- This file stays focused on facts, actual decisions, current intent, and open
  questions rather than generic guidance for AI agents.
- It also stays *short*. It was 694 lines before the 2026-08-02 split, which
  meant every session carried the wake-model pipeline, the Gemini wire
  protocol and the canvas renderer whether or not it touched them. New
  implementation findings go in the matching `docs/` file; this file gets a
  line only when it changes the charter, a standing decision, or where
  something lives.
