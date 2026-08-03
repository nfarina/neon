# Memory

What Neon knows about the household beyond the current conversation.
`MemoryStore.swift` owns it; the store is `~/.config/neon/memories.jsonl`.

## Three kinds, and why this one had to exist

- `~/.config/neon/profile.md` — hand-written by Nick. Durable, but she can't
  add to it.
- `~/.config/neon/conversations.md` — the rolling transcript; the last ~2.5k
  characters go into each new session. Verbatim and short-lived: a fact
  mentioned on Tuesday has scrolled away by Thursday.
- `~/.config/neon/memories.jsonl` — **this**. Facts she decided were worth
  keeping, written one per line, kept indefinitely.

## Store and search

One JSON object per line so the file stays greppable, hand-editable and
append-friendly. Search is keyword scoring, not embeddings: terms are
lowercased, stopped, crudely de-pluralised, then weighted by inverse document
frequency so a rare word ("shellfish") counts for far more than a common one
(a household name), with a small recency/use boost. No model call, no network,
no dependency — and at kitchen scale the retrieval quality is indistinguishable
from embeddings. Verified on a realistic set: "what can she eat" → the
shellfish allergy, "capital of ohio" → correctly nothing.

`remember` de-duplicates on token overlap (>0.6 of the smaller memory) and
keeps the *longer* phrasing, since the newer wording usually carries the extra
detail. Repeating a fact sharpens the memory rather than stacking a copy.

Every `recall` hit increments `uses` and stamps `lastUsed` — the only signal we
have about which memories earn their place, and what dreaming reads.

## How memory reaches the model

Three ways, in decreasing automaticity:

1. **Digest** — the most salient memories (recency + use, ~700 chars) go into
   every session's system prompt unasked. This is the "auto-append" Nick asked
   about, at session granularity.
2. **Wake-utterance recall** — when the wake phrase came with words attached,
   those words are searched *before the session opens* and any hits are added
   to the prompt. So "hey neon, what did I say about the tennis thing" often
   arrives with the answer already in front of her.
3. **`recall` tool** — explicit lookup mid-conversation.

**Per-message auto-injection is not possible with this architecture**, and it's
worth knowing why. The user's speech goes up as *audio*; Gemini's input
transcription comes back clumped *at response time*, after the model has
already begun answering. There is no point at which we hold the text of the
current turn and could search on it before the model sees it. Injecting hits
afterwards would land a turn late — noisy, and usually about the previous
question. Hence the wake-utterance path, which is the one moment we do have
text ahead of the model.

## Watching it work

Memory logs to the event log (**L**) under the `memory` kind: the digest size
at session start, any wake-utterance search, every `remember` and every
`recall` with its hit count.

The digest line matters more than it looks. **Most questions never reach
`recall`** — the salient memories are already in the system prompt, so she
answers from what she "knows" and no tool call happens. Without that line
logged, "she recalled nothing" and "she didn't need to" are indistinguishable,
and it looks like the tool is broken when it is simply unnecessary.

## Dreaming

Live memory is written mid-conversation, one fact at a time, by a model with
seconds to think. It accumulates near-duplicates, things that were true for an
evening, and facts later contradicted. Consolidation is a separate, unhurried
pass — no time pressure, a real reasoning budget, and never while someone is
talking to her.

Nick runs it as a nightly Claude Desktop Routine. The prompt:

```text
Consolidate Neon's long-term memory.

Neon is an AI assistant living on a MacBook in a family kitchen. Who lives
here is in ~/.config/neon/profile.md — read that first.

Read:
  ~/.config/neon/memories.jsonl      — one JSON memory per line
  ~/.config/neon/conversations.md    — raw transcript log (read the tail)

First back up the memory file to ~/.config/neon/memories.jsonl.bak-YYYYMMDD.
Then rewrite ~/.config/neon/memories.jsonl as the memory set as it SHOULD be:

- Merge duplicates and near-duplicates into the clearest single phrasing.
- When two memories conflict, keep the newer and drop the stale one.
- Drop anything only momentarily true ("the pasta timer is set"), anything
  trivially lookup-able, and anything that reads as passing chatter.
- Add durable facts from the conversation log that were never written down:
  preferences, plans, standing arrangements, facts about people.
- Rewrite context-dependent memories as standalone sentences that will still
  make sense in a year ("Alex has tennis on Thursdays", not "it moved").
- Keep it tight. A few dozen genuinely useful memories beat hundreds of
  fragments. When unsure whether something matters, drop it.

Keep the JSON shape per line: id, text, at (ISO8601), uses, lastUsed, source.
Preserve id/at/uses for memories kept unchanged; use source "dream" for
anything merged or added, with `at` set to the newest contributing memory.

Then tell me, briefly: how many memories went in, how many came out, and the
notable merges, drops, and additions.
```

No restart is needed afterwards. `MemoryStore.reloadIfChanged()` runs at the
start of every session and re-reads the file when its modification date moves,
so a consolidated set is live on her next wake. Without that, her in-RAM copy
would silently overwrite the night's work on the next save.
