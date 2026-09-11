---
name: mithlond
description: Use when the user runs /mithlond [note...], /mithlond status, /mithlond heed, or /mithlond depart — or says in plain words "wrap it up everywhere", "tell every session to finish", "call it a day across the board". The Grey Havens — one call asks every live Claude Code session on this machine to wrap up. A session that hears it weighs its own unfinished work: nothing pending, it replies `sailed` and ends its own process; something pending, it leaves a baton on its repo's handoff channel, replies `held: <reason>`, and stays. `status` renders who sailed and who held. Each session only ever ends itself — there is no `pkill`, no cascade.
purpose: Ask every live session to wrap up, and let each decide whether it can.
user_invocable: true
---

# Mithlond

The Grey Havens, where the ships depart. One session raises the call; every
live session hears it on its next turn and decides for itself whether it can
sail. The registry, the call, and the departure are all the hook's:
`~/.claude/hooks/mithlond.sh`. The judgment — is anything unfinished here — is
the model's, in the session that hears the call.

## How the call travels

- **Presence.** `mithlond-presence.sh` registers every session at
  `SessionStart` (its claude pid and directory) and strikes it at
  `SessionEnd`. A session whose process died without that hook firing is
  pruned the next time anyone reads the roster — `kill -0` decides, not the
  hook.
- **The call is a flag, not a message.** `/handoff` channels are queues with
  one consumer per message — the first session to poll would eat the call and
  the rest would never hear it. So the call is one file,
  `~/.skadi/mithlond/call`, and each session's `mithlond-poll.sh`
  (`UserPromptSubmit`) compares it against its own registration: registered
  before the call and not yet heard → the call is injected once. The caller
  is marked heard at once; a session started after the call is not asked. A
  call expires after an hour — a session that slept through the evening is not
  told to leave at breakfast.
- **Pickup is turn-fired.** A session idle at its prompt hears the call when
  its user next types — anything, even `ping`. There is no daemon and no push;
  the best-effort `SendMessage` nudge below is the only wake, and it cannot
  be promised.
- **The word comes back on `mithlond-replies`.** A plain `/handoff` channel,
  read with `read` (which prints without consuming), never `subscribe`. No
  repo is named `mithlond-replies`, so nothing auto-joins it.

## Argument parsing

`/mithlond [verb] [...rest]`

- No arg, or anything that is not a verb below → **call**, with the words as
  the note.
- `status` → render the roster and the replies.
- `heed` → the receiving side: this session has heard the call (the poll hook
  injected it). Follow *Receiving side* below.
- `depart` → this session wraps itself up now, called or not — the same
  *Receiving side* judgment, run on request.
- `help` → print the verbs and stop.

## Verb: call

`/mithlond [note...]`

1. Raise it:

   ```bash
   ~/.claude/hooks/mithlond.sh call <note...>
   ```

   The first line names how many live sessions were called; the TSV after it
   is the roster — `<sid8> <pid> <cwd> <state>`. Render it as a small table.

2. **Live nudge (best-effort).** Call `ListAgents`. For every row that is a
   *local* session and not this one, `SendMessage` it a one-line nudge:
   `Mithlond — a call to wrap up was raised; run /mithlond heed.` Never send
   the roster or the note itself; the flag file is the record, this is a
   wake-up call only. Zero local rows, or a `SendMessage` refusal → say
   nothing of it and move on. This step must never fail the call — the flag
   is already written.

3. Tell the user plainly: N sessions called; idle ones will hear it when they
   next take a turn (type anything in their window); `/mithlond status` shows
   who has sailed and who holds. This session stays open to gather the word
   — run `/mithlond depart` when it, too, should go.

## Verb: status

```bash
~/.claude/hooks/mithlond.sh roster
~/.claude/hooks/handoff.sh read mithlond-replies
```

Join them by `sid8` (the roster's first column is the reply's `from`). Render
one table, one row per session that is either still live or has replied since
the call's `at` (the `call` file's `at:` field; older replies belong to an
earlier call and are dropped):

```
SESSION   WHERE                          STATE
91a5cdc5  ~/skadi                        sailed
c1a7fe28  ~/work/vitallink-ca            held: 2 dirty files, step 3 mid-flight
fe6f3276  ~/phantom/minerva              unheard
```

States, in order of what they mean: `sailed` (replied and gone), `held:
<reason>` (replied, staying), `heard` (took the call, no reply yet — mid-turn),
`unheard` (owes a turn), `after` (started after the call; not asked), `quiet`
(no live call). A session that appears in the replies as `sailed` but is still
on the roster is mid-departure; leave it a moment.

If no call stands, say so and offer `/mithlond <note>`.

## Receiving side — `heed` and `depart`

Run this before any other work in the turn that hears the call.

1. **Weigh what is unfinished.** Two sources, both required:
   - *This conversation* — a step begun and not yet verified, a subagent still
     running, a question put to the user and unanswered, a plan approved and
     not yet worked. A completed task whose "done" report has been rendered
     is finished.
   - *The tree* — run `~/.claude/hooks/eod-git-check.sh "$PWD"`. It answers
     `DIR|STATE|DIRTY|UNTRACKED|AHEAD|BRANCH|REMOTE`. `ok`, `no-git`, and
     `no-remote` are clear; `dirty`, `unpushed`, `both`, and `error` hold.

2. **Nothing unfinished — sail.** In this order, nothing after the last:
   1. One line to the user: `🚢 Sailing — nothing unfinished in <cwd>.`
   2. Reply: `printf 'sailed — <cwd>' | ~/.claude/hooks/handoff.sh send mithlond-replies`
   3. The last tool call of the session:
      `~/.claude/hooks/mithlond.sh depart`
      It signals this session's own claude process, which exits gracefully
      within a few seconds and restores the terminal. Do not queue anything
      after it — there is no after.

3. **Something unfinished — hold.**
   1. Leave a baton on this repo's handoff channel — the one
      `handoff-autosub.sh` named at session start — composed per `/handoff`'s
      baton mode (Branch / Done / Pending / Watch out), so a successor session
      in this repo can pick the work up:
      `printf '%s' "<baton>" | ~/.claude/hooks/handoff.sh send <repo-channel>`
   2. Reply: `printf 'held: <one-line reason> — <cwd>' | ~/.claude/hooks/handoff.sh send mithlond-replies`
   3. Tell the user what holds this session, in the ordinary way, and that
      `/mithlond depart` will sail it once that is settled. Stay.

The reply's `from` defaults to this session's short id, which is what the
roster shows — do not override it with `--from`, or `status` cannot join the
two.

`depart` with no standing call runs the same three steps; the reply lands on
`mithlond-replies` regardless, harmless when nobody is reading.

## Rules

- **Each session ends only itself.** `mithlond.sh depart` signals the one pid
  recorded for this session at `SessionStart`, and only if `ps` still reports
  that pid's command as `claude`. It never searches the process tree and never
  reaches for `pkill` — a depart run in the wrong session fails loud rather
  than finding another ship to sink.
- **The hook never judges.** Whether work is unfinished is decided in the
  session that hears the call, from its own conversation and its own tree.
  The hook records, broadcasts, and signals; nothing more.
- The registry lives at `~/.skadi/mithlond/` — shared across every profile,
  never touched by `/install`.
- The reply channel is read with `handoff.sh read`, never `subscribe` — a
  subscribing session would consume the replies before `status` could show
  them.
