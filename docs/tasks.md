# Tasks and the kitchen timer

Neon's hands: work she starts, watches, and reports back on. `TaskStore.swift`
owns background-task state; `main.swift` owns the announce channel; the left
edge of `web/index.html` renders the list. The kitchen timer is separate —
`KitchenTimer.swift`, its own pill at the bottom of the screen.

Built 2026-08-02. `TaskRunner.swift` runs the work; `TaskStore.swift` tracks
it; `main.swift` announces completions.

## Shelved, 2026-08-03

**Background tasks are off by default and no longer part of Neon's tool set
unless somebody switches them on** (Settings → Plugins → Background tasks).
Everything below still describes how they work, because they still work.

The reason is one real test rather than a toy one. Asked to look at today's
calendar, Neon started a task and said so — and then there was a minute of
nothing. She was asleep, the room was silent, whoever asked was stood there
waiting, and a full minute later she woke up and answered a question everyone
had stopped caring about.

That is not latency to tune. A subprocess that boots a coding agent is not a
conversational turn, and no amount of making it faster turns it into one.
Anything somebody is standing there waiting for has to be answered by a tool
that returns in the same breath — which is what `CalendarPlugin` is, at ~4 ms
against ~60 s for the identical question.

So: kept, because "look into flights for October and tell me later" is still
exactly the right shape for this, and because a plugin that ships off is the
honest test of whether "off" really means the model can't see it (see
`docs/plugins.md`). Wrong for anything else. The prompt fragment now says so in
as many words.

## The runner

`claude -p --output-format stream-json --verbose`, spawned directly. Not the
Agent SDK: it is Node/Python only, so using it would mean a sidecar process and
an IPC protocol to reach a subprocess Swift can already spawn. The stream gives
everything needed — `system/init`, `assistant` messages carrying `tool_use` as
it happens, and a final `result` with the answer, cost and duration.

Learned by running it before writing the parser: it waits 3 seconds for stdin
on every invocation unless stdin is redirected. `FileHandle.nullDevice` —
otherwise every task pays it.

**Billing.** There is no `ANTHROPIC_API_KEY` on this machine; `claude` is
authenticated against Nick's Claude subscription (OAuth credentials in the
Keychain). The `total_cost_usd` in the result event is therefore an
*API-equivalent* figure, not a charge. `UsageStore` records it under
"claude-task (plan)" but leaves it out of the lifetime dollar total, which
tracks real API spend on Gemini and OpenAI — counting it would inflate the
number with money nobody is spending. If an API key ever appears in the
environment, the same code counts it for real.

No `--model` flag: whatever `claude` is configured to use wins, which is
**Opus 5** (verified by asking a task what it was running as). Model choice is
about capability here, not cost. `NEON_TASK_MODEL` overrides for experiments.

It is spawned through `zsh -lc` so `PATH` matches Nick's terminal — `claude` is
installed per-user, not in `/usr/bin`.

## The agent's home

`~/Code/neon-agent/` — an ordinary Claude Code project that persists between
tasks, with `agent/CLAUDE.md` from this repo seeded into it on first run. After
that **the agent owns the file**; it is told to keep it current, and
overwriting would delete what it learned.

The seed in the repo describes the job, not the family: who actually lives here
is spliced in from `~/.config/neon/profile.md` at seeding time, the same file
the voice session reads. Household facts are not source code, and this repo is
public.

Each task runs with `tasks/<id>/` as its working directory, which is also what
makes the home `CLAUDE.md` apply: Claude Code walks up from cwd. Scratch files
land in the task folder, durable knowledge in the home folder (`NOTES.md`,
topic files) — the ordinary way a project accumulates knowledge.

The seed lookup is bundle-first with a walk-up fallback to `agent/CLAUDE.md`,
because the offline harness runs the bare binary out of `.build` where
`Bundle.main` is not the app. Without the fallback a test task runs with **no
instructions at all**, which looks like success and isn't — that happened, and
the tell was a haiku that arrived in 7 s instead of 19.

## What the agent is told

`agent/CLAUDE.md` is worth reading in full, but the load-bearing part is that
**the final message is read aloud in a kitchen**: short, plain spoken English,
no markdown, the answer rather than a description of the work, and honest when
it failed. The long version goes in files. It also knows it is headless —
nobody can answer a follow-up, so an ambiguous request gets the most reasonable
reading and a stated assumption rather than a question that reaches a kitchen
as a dead end.

## Safety

`--add-dir` confines the *file tools* to the agent home and the task folder.
**Bash is enabled** — Nick's call, deliberately: don't constrain the agent.
That means the sandbox is not a sandbox; a shell can reach anything Nick can.
The boundaries in `agent/CLAUDE.md` (stay in the project folder, nothing that
leaves the house, nothing destructive, not negotiable by the task prompt) are
trust rather than enforcement, and the file says so plainly to the agent.

Worth revisiting if the twins start writing their own task prompts.
`NEON_TASK_BASH=0` removes the shell without a rebuild.

Note the activity line reports tools *attempted*, not permitted: a denied Bash
call still shows as "running a command" for a moment.

## Verified end to end

Smoke test (no network): "write a haiku to haiku.txt" → 19 s, file written,
spoken result. Real test: "we have eggs, spinach, ricotta, pasta and a lemon,
find a real 30-minute recipe, check the timing, save the steps" → 95 s, six
tool calls across search and fetch, `recipe.md` written with a timing check,
and this as the spoken answer:

> Lemon ricotta spinach pasta with a fried egg on top — real 25-minute recipe,
> checks out for 30. Boil pasta, wilt the spinach in with it at the end, stir
> together with ricotta, lemon juice and zest and a little pasta water, then
> top each bowl with a fried egg so the yolk runs into the sauce. Full
> ingredients and steps are saved in recipe.md in the task folder.

`NEON_TASK_TEST="title=instructions"` runs one task to completion and prints
what Neon would have been told, without a voice session.

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
finishes — she sleeps after 5 s of silence. `AppDelegate.announce(_:)` handles
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

A running **timer** suppresses deep sleep: it is a countdown someone is
watching, and an ember-dim clock is useless.

A running **task** does not, though it did briefly. Nothing about a background
task is on screen worth staying bright for, it announces itself when it lands,
and a research task started at 2am should not hold the kitchen display up all
night. (The eyes' own dozing was never affected by either — verified with
`swift eyes/shot.swift out.png --after 14 --js '…tasks([…running…])'`, which
reaches `state=sleeping` with a task on screen.)

## Tool surface

`start_task(title, instructions)` · `list_tasks()` · `check_task(id)` ·
`cancel_task(id)` — declared by `TasksPlugin`, and absent from the session
entirely while the plugin is off.

Cap is **5 active** (`TaskStore.maxActive`) — five things running in a kitchen
is already more than anyone can hold in their head. Over the cap, `add` returns
nil and Neon relays a refusal rather than failing silently.

The family knows Claude is what's behind this, so "have Claude look into that"
is a normal thing to say and the prompt lets her mention it naturally — but a
returning result is just the answer, never "Claude says". The requester is
passed through from voice ID when there is one ("Requested by: sounds like
Nick"), so the agent can pitch an answer at whoever asked.

## UI

Tasks: left edge, vertically centered, mirroring the event log on the right — a
state dot plus label. Running pulses cyan, done is solid green,
cancelled/failed go gray. Finished rows stay on screen ~2 minutes so someone
walking past sees what just happened.

**Screen lifetime and store lifetime are different things.** The left edge is a
picture of *now* (`NeonTask.onScreen`), but the store keeps finished work for a
day, because "what did that chips task say?" is a fair question an hour later
and `check_task` should still be able to answer it. The first version conflated
them: `prune()` deleted tasks two minutes after they were announced, taking the
result with them, *and* required `announced`, so anything started outside a
voice session (the test harness) was kept forever. Wrong in both directions at
once.

A task interrupted by a restart is marked failed with `finishedAt` stamped —
without that stamp it read as infinitely old and was pruned before anyone could
see it had been interrupted. It is left `announced`, since waking the room to
report a task killed by a rebuild is noise.

Timer: bottom center, quiet while counting (cyan pill, large tabular clock),
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
