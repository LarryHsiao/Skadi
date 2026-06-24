---
name: handoff
description: Use when the user runs /handoff send <channel> [message], /handoff read <channel>, or /handoff list. An async file mailbox between Claude Code sessions — one session leaves a message (or a whole context baton) on a named channel, another picks it up on demand. Manual pickup, no server. Messages live under ~/.skadi/handoff/.
user_invocable: true
---

# Handoff Skill

A baton passed between sessions. One session writes a message to a named
channel; another session reads that channel when you prompt it. Sessions are
turn-based — there is no live push — so pickup is manual: you run `/handoff read`
in the receiving session. Request and reply are just two messages on one channel.

## Storage

- One folder per channel under `~/.skadi/handoff/<channel>/`.
- Each message is an append-only file `<utc-timestamp>-<from>.md` with a
  `from`/`at` frontmatter and a body.
- The directory is created lazily by the hook; never pre-create it from the skill.

All file work is the hook's: `~/.claude/hooks/handoff.sh`. The skill orchestrates
the verbs and, in baton mode, composes the body.

## Argument parsing

`/handoff [verb] [...rest]`

- No arg or `help` → print the three verbs and stop.
- `send <channel> [message...]` → send a message (baton mode when no message).
- `read <channel>` → print the channel thread.
- `list` → list channels.
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
- Pickup is manual. Do not spin up a poll loop or a server; that was weighed and
  rejected (see `docs/superpowers/specs/2026-06-24-handoff-design.md`).
