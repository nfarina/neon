# Tasks and the kitchen timer

Neon's hands: work she starts, watches, and reports back on. `TaskStore.swift`
owns background-task state; `main.swift` owns the announce channel; the left
edge of `web/index.html` renders the list. The kitchen timer is separate —
`KitchenTimer.swift`, its own pill at the bottom of the screen.

Built 2026-08-02. **`TaskStore` is dormant**: no task tools are declared, so
nothing can create one, and the left-edge list renders empty. The announce
channel and the store are wired and tested, waiting on the agent runner —
`claude -p` in a sandbox — which Nick parked to build memory first.

## The kitchen timer is not a task

Timers were built as a task producer, and one kitchen test settled it: the
timer fired, Neon woke up, and announced "quick check is done". Wrong on every
axis. A timer going off doesn't want a conversation — it wants to be obvious in
the room and trivial to silence. Nick's call: make it first-class, one at a
time, with its own UI and its own alarm state.

So `KitchenTimer` is a separate singleton with no relation to `TaskStore`:

- **One timer.** `set_timer` replaces whatever was running. Two timers in a
  kitchen is a feature request, not a default.
- **It rings itself.** No session, no wake, no tokens. An amber pill pulses at
  the bottom of the screen and a synthesized two-tone chime repeats every 2.4 s
  — a timer that dings once from another room may as well not have gone off.
- **Three ways to stop it**: space (works from across the counter), a click
  anywhere, or telling Neon to stop — the only path that costs a session, and
  only because someone chose to talk instead of reaching over.
- The chime plays through `AudioHub`, not `NSSound`, so echo cancellation
  subtracts it from the mic. She has to hear "Neon, stop" over her own alarm.
- The cursor is normally hidden; a ringing timer is the one state that brings
  it back, because Nick asked to be able to click the thing off.
- A running or ringing timer suppresses deep sleep. An ember-dim panel is the
  wrong state for a countdown someone is waiting on.
- It persists. A timer whose moment passed while the app was quit restores
  straight into the ringing state rather than pretending it never happened.

Tools: `set_timer(label, seconds)` · `check_timer()` · `stop_timer()`. The
prompt tells her she is *not* the alarm — confirm briefly ("five minutes,
going") and never promise to tell them when it's up.

## Why background tasks still route through her

`TaskStore` keeps the announce channel because work that produces a *result*
is worth a session: there's something to say, and no screen affordance conveys
"the thing you asked me to find out came back". The split is the point —
completion that is an **event** (a timer) rings; completion that is an
**answer** speaks.

## The announce channel

The hard part is not running work, it's that Neon is *asleep* when the work
finishes — she sleeps after 7 s of silence. `AppDelegate.announce(_:)` handles
three cases:

- **Session live** → `VoiceSession.inject(note)` sends the completion as a user
  turn, which she works into whatever she's saying.
- **Asleep** → `triggerWake(command: note)`. This is the openWakeWord path with
  a different trigger: the eyes open, she announces, and the prompt tells her to
  call `go_to_sleep` unless someone answers.
- **Deep asleep** → same thing. Nick's call, 2026-08-02: anything may wake the
  room for now, and we dial it back if it proves annoying at 3 am. Gate it in
  `announce` if so.

Injected notes arrive as *user* turns because that is the only role the live API
accepts after setup. The system prompt therefore explains that anything in
square brackets is an event from the house rather than someone speaking, and
that she should call it out the way a person would ("pasta's done") — never the
id, never the word "task", never that a tool told her.

`announced` is persisted per task, so a completion survives a crash without
being announced twice.

## Deep sleep

A running task suppresses deep sleep entirely (`checkIdle` returns early while
`TaskStore.active` is non-empty). Deep sleep takes the backlight to an ember,
which is the wrong state for a display counting down to something somebody is
waiting for.

## Tool surface

Cap is **5 active** (`TaskStore.maxActive`) — five things running in a kitchen
is already more than anyone can hold in their head. Over the cap, `add` returns
nil so the model can relay a refusal rather than failing silently. The task
tools themselves (`start_task`/`list_tasks`/`check_task`/`cancel_task`) land
with the runner; only the timer tools are declared today, to keep the tool list
short.

## UI

Tasks: left edge, vertically centred, mirroring the event log on the right — a
state dot plus label. Running pulses cyan, done is solid green,
cancelled/failed go grey. Finished rows linger ~2 minutes (`prune()`) so
someone walking past sees what just happened.

Timer: bottom centre, quiet while counting (cyan pill, large tabular clock),
amber and pulsing when ringing, with the dismissal hint spelled out on screen.

Both countdowns tick **in the page**, not over the bridge — the shell pushes
state only when it changes and JS stamps arrival time, so a ticking clock costs
nothing per second.

## Testing without talking

`TaskStore` and `KitchenTimer` are (nearly) pure Foundation, so both self-test
as scripts: copy the file, redirect the JSON path, stub `chime()` — which is
the only part needing the audio engine — and nothing makes a sound in the
kitchen. Verified this way: cap enforcement, cancel with real and bogus ids,
timer set/replace/fire/repeat-chime/stop, that a second stop returns false, and
that the persisted file is removed. The UI is verifiable with
`swift eyes/shot.swift out.png --js 'window.neon.timer({...})'`.
