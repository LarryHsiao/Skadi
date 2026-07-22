---
name: handoff
description: Use when the user runs /handoff send <channel> [message], /handoff read <channel>, /handoff list, /handoff subscribe <channel>, or /handoff clear <channel>. An async file mailbox between Claude Code sessions — one session leaves a message (or a whole context baton) on a named channel, another reads it on demand or subscribes for live auto-pickup. No server. Messages live under ~/.skadi/handoff/.
user_invocable: true
---

# Handoff Skill

A baton passed between sessions. One session writes a message to a named
channel; another session reads that channel. Request and reply are just two
messages on one channel.

Pickup comes in two grades. **On demand** — run `/handoff read <channel>` in the
receiving session whenever you want the thread. **Live** — `/handoff subscribe
<channel>` once, and from then on every turn auto-picks-up new messages on that
channel without a `read`. Sessions are turn-based — there is no instant push — so
"live" means the message lands the next time the receiving session takes a turn.

**The repo's own channel needs no subscribing.** At session start the
`handoff-autosub.sh` hook joins this session to a channel named for the git
toplevel it stands in — a session in `~/phantom/skadi` lands on `skadi` — so two
sessions in one repo are already live to each other with nothing typed. A session
standing outside any repo has no repo to name and joins nothing. Reach for the
`subscribe` verb only to join a channel *outside* the current repo, or to trade
the default identity for a chosen name.

**Sending to a session in another repo: name the channel after that repo.** A
session rooted elsewhere already auto-joined the channel named for its own
toplevel, sanitized the same way `send` sanitizes it — so `send <target-repo>
<message>` lands on a channel the target session is already watching, and the
baton shows up live on its next turn with no `subscribe` or `read` required on
that end. This only holds when the target stands in a repo; a target outside
any repo has no auto-channel, so fall back to an explicitly-shared name there.

## Storage

- One folder per channel under `~/.skadi/handoff/<channel>/`.
- Each message is an append-only file `<utc-timestamp>-<from>.md` with a
  `from`/`at` frontmatter and a body.
- The directory is created lazily by the hook; never pre-create it from the skill.

All file work is the hook's: `~/.claude/hooks/handoff.sh`. The skill orchestrates
the verbs and, in baton mode, composes the body.

## Argument parsing

`/handoff [verb] [...rest]`

- No arg or `help` → print the verbs and stop.
- `send <channel> [message...]` → send a message (baton mode when no message).
- `read <channel>` → print the channel thread.
- `list` → list channels.
- `subscribe <channel>` → watch a channel for live auto-pickup this session.
- `clear <channel>` → remove a channel's messages (confirm first).

The sender tag (`from`) defaults to a short slice of this session's id; pass
`--from <label>` anywhere in a `send` to override it with a human name
(`reviewer`, `laptop`).

## Verb: send

`/handoff send <channel> <message...> [--from <label>]`

Pipe the literal message to the hook — the body is read from stdin so quoting
and newlines stay clean:

```bash
printf '%s' "<message>" | ~/.claude/hooks/handoff.sh send <channel> [--from <label>]
```

Show the hook's one-line confirmation to the user.

### Baton mode — `send` with no message

`/handoff send <channel> [--from <label>]`

When no message is given, compose a context baton for the receiving session,
then pipe it to the same hook `send`. Gather the git state with the existing
hook rather than inventing checks:

```bash
~/.claude/hooks/eod-git-check.sh "$PWD"
```

That returns `DIR|STATE|DIRTY|UNTRACKED|AHEAD|BRANCH|REMOTE`. From it and the
conversation so far, write a short markdown baton naming:

- **Branch** — the current branch and whether work is uncommitted / unpushed.
- **Done** — what this session accomplished, in a line or three.
- **Pending** — what is left, with concrete file:line pointers where they help.
- **Watch out** — any trap the next session should know.

Keep it tight — a baton, not a report. Then send it:

```bash
printf '%s' "<composed baton>" | ~/.claude/hooks/handoff.sh send <channel> [--from <label>]
```

## Verb: subscribe

`/handoff subscribe <channel> [--from <label>]`

Watch a channel so this session auto-picks-up its new messages every turn — no
`read` needed. Run it once per channel (one channel per call); each call adds to
this session's subscription.

The repo's own channel is joined automatically at session start (see above), so
this verb serves the other cases.

```bash
~/.claude/hooks/handoff.sh subscribe <channel> [--from <label>]
```

Show the hook's one-line confirmation, naming the resolved channel and identity.

**Live pickup is automatic.** Once subscribed, a `UserPromptSubmit` hook
(`handoff-poll.sh`) injects new messages on each turn — the skill does nothing
further. A message is picked up when it sits on a subscribed channel **and** its
`from` differs from this session's own identity (a session never hears its own
echo). The read cursor advances per channel, so each message is shown once.

**The two sides must wear different names.** A channel is the meeting place, not
the address — both sessions `subscribe` to the *same channel*, but each must pass
a *different* `--from`. The self-filter keys on `from`: if both called themselves
`reviewer`, each would mistake the other's notes for its own and pick up nothing.
Same channel, different names — that is what makes the two-way flow work. The
identity set here also becomes this session's default `from` for `send`.

Left alone, the default already satisfies this: each session's `from` is a slice
of its own session id, distinct by construction. That is why
`handoff-autosub.sh` leaves identity to the default rather than naming a session
after the repo it stands in — sessions sharing a repo would then share a name,
and the self-filter would silence every one of them. The warning above binds only
when you override with `--from`.

## Verb: read

`/handoff read <channel>`

```bash
~/.claude/hooks/handoff.sh read <channel>
```

Render the thread to the user oldest-to-newest. If the hook reports no messages,
relay that plainly and suggest `/handoff list` to see live channels.

## Verb: list

`/handoff list`

```bash
~/.claude/hooks/handoff.sh list
```

Output is TSV: `channel \t count \t last-activity`. Render it as a small table:

```
CHANNEL        MESSAGES  LAST ACTIVITY
review-foo     3         2026-06-24T10:30:00Z
deploy         1         2026-06-23T18:02:11Z
```

If the hook reports no channels, say so and suggest `/handoff send <channel> …`
to open one.

## Verb: clear

`/handoff clear <channel>`

A channel's messages are append-only and persist until cleared — `read` never
consumes them. This verb removes a spent channel. It is destructive, so it
carries its own confirm gate (like `/commit` and `/reset`):

1. Read the channel first so the count is known:

   ```bash
   ~/.claude/hooks/handoff.sh read <channel>
   ```

2. Ask the user via `AskUserQuestion` to confirm deletion, naming the channel
   and how many messages will go. On **no**, stop and change nothing.

3. On **yes**, clear it:

   ```bash
   ~/.claude/hooks/handoff.sh clear <channel>
   ```

   Relay the hook's one-line confirmation. If the hook reports no such channel,
   say so plainly.

## Rules

- The mailbox lives at `~/.skadi/handoff/` — shared across every profile, never
  touched by `/install`.
- Channel names are lowercased and sanitized by the hook; `Feat/Foo` becomes
  `feat_foo`. Tell the user the resolved name if it differs from what they typed.
- The hook only ever appends a body it is handed. Composing a baton is the
  skill's job — the judgment of what to summarize is the model's, not bash's.
- Live pickup is turn-fired, not a daemon. The `handoff-poll.sh`
  `UserPromptSubmit` hook runs only when the receiving session takes a turn; no
  server, no long-poll loop. That distinction was weighed and the daemon
  rejected (see `docs/superpowers/specs/2026-06-24-handoff-design.md`).
- Subscriptions and read cursors are per session, kept under the hidden
  `~/.skadi/handoff/.subs/` and `~/.skadi/handoff/.cursors/` — never shown as
  channels by `list`, never composed by the model.
