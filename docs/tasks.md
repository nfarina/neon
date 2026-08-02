# Tasks

Neon's hands: work she starts, watches, and reports back on. `TaskStore.swift`
owns the state; `main.swift` owns the announce channel; the left edge of
`web/index.html` renders it.

Phase 1 (2026-08-02) is timers end to end. The agent runner — `claude -p` in a
sandbox — plugs into the same lifecycle next.

## Why timers are not agent tasks

The motivating example was "set a timer for 5 minutes", and it is exactly the
job an agent should *not* do. `claude -p "sleep 300, then report"` parks a model
process to watch a clock: it bills tokens, it dies with the app, and it drifts.
A stored fire date is exact, free, and survives a relaunch.

So the design splits **producers** from the **announce channel**. Timers are one
producer, agent tasks are another, and both share one lifecycle, one on-screen
list, and one way of speaking up. The most common kitchen request stays the
cheapest one.

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

`set_timer(label, seconds)` · `list_tasks()` · `cancel_task(id)`. The label is
2-4 words because it is what the UI shows. `list_tasks` is separate from a
per-task check so the common "what's running?" stays one cheap call.

Cap is **5 active** (`TaskStore.maxActive`) — five things running in a kitchen
is already more than anyone can hold in their head. Over the cap, `set_timer`
returns a refusal the model can relay rather than failing silently.

## UI

Left edge, vertically centred, mirroring the event log on the right: a state dot
plus label, with a countdown for timers. Running pulses cyan, done is solid
green, cancelled/failed go grey. Finished rows linger ~2 minutes (`prune()`)
so someone walking past sees what just happened.

The countdown ticks **in the page**, not over the bridge — the shell pushes the
list only when it changes, and JS stamps arrival time and counts down locally.
A running timer costs nothing per second.

## Testing without talking

`TaskStore` is pure Foundation, so it self-tests as a script: copy it, redirect
the JSON path, exercise it, and nothing speaks in the kitchen. Verified this
way: cap enforcement, cancel (real and bogus id), the countdown summary, firing,
and the persisted file. The UI is verifiable with
`swift eyes/shot.swift out.png --js 'window.neon.tasks([...])'`.
