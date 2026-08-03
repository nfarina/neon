# Plugins and settings

What Neon can do beyond being Neon, and the panel where you turn it on.

`Plugins.swift` is the framework; `TimerPlugin.swift`, `CalendarPlugin.swift`
and `TasksPlugin.swift` are the three that exist. `Settings.swift` is the
bridge; the panel itself is the `#settings` block in `web/index.html`.

Built 2026-08-03, out of a failure worth keeping in front of us — see "why
this exists" at the bottom.

## What is and isn't a plugin

Core is Neon herself: ending the conversation, looking through the camera,
showing a feeling, remembering. Those are what make her her, they are declared
in `coreTools` and handled inline in `VoiceSession`, and none of them is
switchable.

A plugin is a capability somebody might reasonably not want, or not be allowed:
a calendar she can read, a timer, a way to hand work to Claude Code. The unit
is **what reaches the model** — tool declarations, a paragraph of system
prompt, and optionally a macOS permission.

The load-bearing property: turning a plugin off does not disable a code path,
it removes the tools from `setup` entirely. The model never learns the
capability exists. A tool that is declared and then refused is a tool the model
will keep trying, apologize for, and mention; a tool that was never declared is
one it has no concept of. That is the only kind of "off" a language model
respects.

The prompt fragment travels *with* the tools for the same reason. Two places
that both describe what she can do is two places that can disagree.

## Writing one

```swift
final class ThingPlugin: NeonPlugin {
    let id = "thing"                    // stable — it is the key in plugins.json
    let title = "Thing"                 // settings panel
    let blurb = "One line for whoever is deciding whether to switch it on."
    let defaultEnabled = false
    let permission: PluginPermission? = nil
    var tools: [ToolSpec] { [ … ] }
    let promptFragment: String? = "When to use it, in her voice."

    func handle(tool: String, args: [String: Any], context: PluginContext,
                reply: @escaping PluginReply) { … }
}
```

Add it to `PluginRegistry.all` — registration order is display order.

`ToolSpec`/`ToolParam` are provider-neutral; the engines render Gemini's
uppercase `OBJECT`/`STRING` and OpenAI's lowercase JSON Schema from the same
declaration. This also quietly fixed something: the OpenAI engine used to
declare `go_to_sleep` and nothing else, because the tool list was hand-written
per engine and only Gemini's was kept current.

Handlers reply through a callback rather than returning, so a plugin that has
to go away and do something doesn't block the session's message loop.

## Permissions

`PluginPermission` covers the case where macOS has to be asked. Three states,
and the only interesting one is `.notDetermined` — the only state where asking
raises a dialog rather than silently failing. After a denial macOS will not ask
again, so the panel stops offering and tells you where the switch is instead.

**Asking happens in settings, on a click.** Calendar access used to be
requested at launch, which was a workaround for something worse: asking lazily,
the first time a tool wanted it, put the dialog behind a fullscreen kiosk
window with process switching disabled, so the system waited forever on a click
nobody could deliver. Settings solves it properly — somebody is standing at the
machine, they just pressed the button, and `onNeedsScreen` steps the kiosk
aside first.

An enabled plugin whose permission was refused stays enabled and stays listed,
with the reason on screen, but its tools stay out of the session: a tool that
can only fail is worse than an absent one.

State is `~/.config/neon/plugins.json`, outside the repo, so a fresh clone
starts at the defaults rather than inheriting this house's choices.

## The settings panel

`,` opens it (`⌘,` too). It is a web overlay rather than a Mac window, because
Neon is not a Mac app to the person standing at the counter — she is a face on
a screen, and the place you change what she can do should look like it belongs
to her.

**Opening settings puts her to sleep**: the session closes, the eyes shut, and
every wake path is gated for as long as the panel is up. Nobody wants to be
overheard by the thing whose microphone settings they are reading, and a wake
mid-edit would be absurd. Announcements that land meanwhile are *held*, not
dropped, and delivered when it closes.

The wake listeners keep running rather than being stopped. `OpenWakeListener`
has no stop — it is built to run for months — and the deafness watchdog exists
precisely to restart a listener that went quiet, so stopping one deliberately
would have the watchdog fighting to bring it back. Gating the detections is the
honest equivalent and cannot leave her deaf afterwards.

### The bridge

This is the first thing that talks *back* to the shell. Until now it was
`evaluateJavaScript` in one direction and nothing coming back; now the page has
a `WKScriptMessageHandler` and posts `{action: …}` to
`webkit.messageHandlers.neon`.

The shell pushes one whole state object and the panel re-renders all of it.
Diffing across a bridge is how you get a toggle that disagrees with the file on
disk, and the surface is small enough that rebuilding it costs nothing.

Two things that only look like details:

- **The keyboard changes hands.** The single-letter shortcuts (`d`, `l`, `s`…)
  are swallowed by the shell's key monitor, which would fire them while
  somebody is typing their household into a text box. With the panel open every
  key goes through to the page except Esc.
- **The camera preview is patched, not re-rendered.** Frames arrive at 4 fps;
  replacing the `<img>` element each time makes it flash white while the new
  data URI decodes. `paintSitting()` writes the sitting screen once and updates
  fields in place.

### Enrollment moved in

`Enrollment.swift` was a blocking loop printing to stdout. It is now
`EnrollmentSession`, driven by timers, with `onProgress`/`onPreview`/
`onFinished`; the terminal path (`NEON_ENROL=Sam`) is a thin wrapper that pumps
the run loop and prints. Blocking the main thread would have frozen the very UI
showing the countdown.

The panel adds a mirrored live preview, which is worth more than it sounds —
"look at the camera for eight seconds" without seeing yourself is how you end
up with six excellent embeddings of your ear.

### Checking it without a screen

```sh
NEON_SETTINGS_TEST=1 eyes/Neon.app/Contents/MacOS/Neon
```

Prints the state object the panel would be handed, which plugins are on, and
the exact tool surface the session would declare. That last list is the point:
it is how you confirm that switching something off really removes it rather
than merely refusing it later.

## Why this exists

The background-task system worked and was still wrong. Asked to check today's
calendar, Neon would start a task and say so — and then there was a minute of
nothing. She was asleep, the room was silent, whoever asked was stood there,
and a full minute later she woke up and answered a question everyone had
stopped caring about.

The latency isn't a bug to tune. A subprocess that boots a coding agent is not
a conversational turn. Real-time answers have to come from tools that return in
the same breath — which is what `CalendarPlugin` is, and it is ~4 ms against
~60 s.

So tasks are shelved rather than deleted: still right for work that is
genuinely long, wrong for anything anybody is waiting on, and off by default.
It is also the honest test of this system — a plugin whose whole job is to
prove that "off" means the model can't see it.
