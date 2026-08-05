<img width="500" height="375" alt="Neon" src="https://github.com/user-attachments/assets/1ffb5cea-f863-4fdc-904c-7788ea350bc1" />

# Neon

An ambient voice assistant that lives on your spare Mac in your kitchen.

She is a pair of glowing eyes on a screen. Say "Hey Neon"
and the eyes open; talk, and she talks back — a real conversation over a
realtime speech-to-speech model, not a command line with a voice. She sets a
timer, reads the family calendar, looks through the camera when seeing would
help, remembers what you told her last week, recognizes who is talking, and
puts herself back to sleep when the room goes quiet.

She was built as a replacement for an Alexa in a kitchen, by someone who wanted
one that could actually hold a conversation.

## What she does

- **Wakes on "Hey Neon"** — a locally trained openWakeWord model, on-device,
  no audio leaves the machine until she is awake.
- **Talks** — Gemini Live by default (OpenAI Realtime is wired up too), with
  web search grounding and her reasoning visible in her face while she thinks.
- **Sees** — one camera frame on demand, when looking would help. Not a stream.
- **Sets one kitchen timer** that rings itself, loudly, and can be silenced by
  hitting space from across the counter.
- **Reads the calendar** this Mac already syncs, so "what's on today" is
  answered in the same breath it was asked.
- **Remembers** across conversations, and consolidates it overnight.
- **Knows who is speaking** by voice and by face, as a hedge and never as a
  gate — it makes her warmer, it is not a login.
- **Sleeps.** Really sleeps: eyes shut, then the backlight down to an ember
  after ten quiet minutes, because a bright rectangle in a dark kitchen at 2am
  is light pollution.

## Requirements

- A Mac running macOS 14 or later, that you are willing to leave switched on.
  Neon runs as a fullscreen kiosk; the machine becomes an appliance.
- Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- A [Gemini API key](https://aistudio.google.com/apikey). Expect a few dollars
  a month for ordinary household use.

## Getting started

```sh
git clone https://github.com/nfarina/neon.git
cd neon
mkdir -p ~/.config/neon
echo "GEMINI_API_KEY=your-key-here" > ~/.config/neon/secrets.env
./eyes/rebuild.sh --run
```

The first launch asks for the microphone, speech recognition and location. Say
"Hey Neon".

Press **`,`** for settings — plugins, who lives here, enrolling voices and
faces, and updates. Press **Tab** to see the other keys. The way *out* of the
kiosk is Ctrl-Opt-Cmd-Q, which is deliberately awkward: it is the shortcut that
takes a guest from Neon to your logged-in desktop.

Run with `NEON_DEV=1` while you are working on her, which leaves Cmd-Tab and
the rest of the machine reachable.

## Plugins

Anything Neon might reasonably not be allowed to do is a plugin, switched on
and off in settings. Turning one off does not disable a code path — it removes
the tools from the session entirely, so the model never learns the capability
exists, which is the only kind of "off" a language model respects.

| Plugin | Default | |
|---|---|---|
| Kitchen timer | on | One timer, rings on screen by itself. |
| Calendar | off | Read-only access to the calendars this Mac syncs. There is no write path in the code. |
| Background tasks | off | Hands longer work to Claude Code. Slow, and the agent it starts has a shell with your access — read `docs/tasks.md` before enabling it. |

Adding one is a file: see `Plugins.swift` and any of `TimerPlugin.swift`,
`CalendarPlugin.swift`, `TasksPlugin.swift`.

## Making her yours

- **`~/.config/neon/profile.md`** — who lives here, in your own words. She
  reads it at the start of every conversation. Editable from settings.
- **The wake word.** "Hey Neon" ships trained. `wake/README.md` is a complete
  pipeline for training your own phrase in a container, including recording
  your own voice for the part synthetic data can't teach.
- **Voices and faces.** Two model downloads (`docs/people.md`), then a
  twenty-second sitting per person in settings. Enrollment photographs are
  never written to disk.
- **Her personality** is a paragraph at the top of `VoiceSession.swift`.

Everything personal — keys, the household profile, memories, transcripts,
voiceprints and faceprints — lives in `~/.config/neon/`, outside this
repository, on purpose.

## How it is put together

A single Swift executable (`eyes/shell/`) hosting a `WKWebView` that draws the
eyes on a canvas (`eyes/web/index.html`). No Xcode project, no storyboards;
`eyes/rebuild.sh` assembles `Neon.app` by hand. The only dependencies are ONNX
Runtime, for the wake word and the recognition models, and Sparkle, for
updates.

The interesting parts each have their own notes:

| | |
|---|---|
| [docs/voice.md](docs/voice.md) | The realtime session: engines, lifecycle, tools, cost |
| [docs/wake.md](docs/wake.md) | Waking her, and why it is two listeners rather than one |
| [docs/eyes.md](docs/eyes.md) | The renderer, the animation channels, the emotes |
| [docs/people.md](docs/people.md) | Recognizing voices and faces, and where it goes wrong |
| [docs/memory.md](docs/memory.md) | What she remembers, and the nightly pass |
| [docs/plugins.md](docs/plugins.md) | The plugin system and the settings panel |
| [docs/tasks.md](docs/tasks.md) | The timer, and the shelved background-task system |
| [docs/machine.md](docs/machine.md) | The machine, and the permissions that keep breaking |
| [docs/release.md](docs/release.md) | Cutting a release people can install |
| [wake/README.md](wake/README.md) | Training a wake word end to end |
| [AGENTS.md](AGENTS.md) | The charter — read this first if you are an AI |

## A caution

Neon runs on a Mac logged into a real person's account, on purpose: that is how
she reaches a real calendar. The kiosk closes the obvious ways off her, but she
is a convenience for a household, not a security boundary. Do not put her
somewhere strangers can use her, and read `docs/tasks.md` in full before
switching the background-task plugin on.

## Licence

MIT. See [LICENSE](LICENSE).
