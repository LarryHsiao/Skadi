# `/handoff` — async file mailbox between sessions

**Date:** 2026-06-24
**Status:** design, awaiting review

## Purpose

Let one Claude Code session pass a message — or a whole context baton — to
another session, addressed by a named channel and picked up on demand. The
canonical use is two concurrent sessions exchanging notes: a worker session
hands a reviewer session "here is the branch, here is what to check," and the
reviewer answers on the same channel.

## Why no server

The path to a server was weighed and rejected. A Claude Code session is
**turn-based**: it acts on a user turn or a scheduled wake-up, and bears no
inbound port — it cannot be interrupted mid-thought by an external message. So
"live request/reply" cannot mean instant reaction; the receiver picks up a
message only when it next takes a turn. With **manual pickup** chosen (the human
runs `/handoff read` in the receiving session), there is no long-polling to
serve and no liveness to track. A server would add a daemon and a port while
buying nothing the filesystem does not already give. The mailbox is plain files.

## Storage

Root: `~/.skadi/handoff/<channel>/` — one folder per channel.

- **Profile-agnostic.** Lives outside every Claude config root, so all sessions
  see the same mailbox regardless of which profile (`~/.claude`,
  `~/.claude-personal`, `~/.claude-work`) launched them. Follows the precedent
  `/vocab` set with `~/.skadi/vocab/`.
- **Untouched by `install.sh`.** It is runtime data, not config, so an install
  sweep never overwrites it.

Each message is **one append-only file**, named `<utc-timestamp>-<from>.md`:

```
---
from: reviewer
at: 2026-06-24T10:30:00Z
---
Migration is on branch feat/foo, tests green. Please review the SQL in
db/migrate.sql:40 before I push.
```

Append-only is the design's quiet virtue: no two sessions ever write the same
file, so there is no write contention and no locking. The timestamp in the
filename gives thread order for free.

## Identity — the `from` field

Defaults to a short slice of the sending session's id (derived from its
scratchpad path). Overridable with `--from <label>` so a session can wear a
human name — `laptop`, `reviewer`, `worker`. Zero friction by default,
nameable when it matters.

## Verbs

### `/handoff send <channel> <message> [--from <label>]`
Append a literal message to the channel.

### `/handoff send <channel> [--from <label>]` — baton mode
With no message argument, the **skill** (not the hook) composes a context
baton from the current session: the git branch, recent/uncommitted work, and
what is left pending — `/eod` distilled into a single note. The composed body
is then handed to the hook's append, exactly as a literal message would be.

The split matters: summarizing a session needs the agent's judgment, so the
skill builds the body; the hook only ever appends a body it is given.

### `/handoff read <channel>`
Print the channel thread oldest-to-newest, each message with its `from`/`at`
header. Threads are short; show the whole thread, no read cursor.

### `/handoff list`
List channels with message counts and last-activity time.

## Skill / hook split

Per the skadi rule that complex bash never lives inline in a skill:

- `skills/handoff/SKILL.md` (`name: handoff`, `user_invocable: true`) —
  orchestrates the verbs, composes the baton note in baton mode, calls the hook.
- `hooks/handoff.sh send|read|list …` — the file work: resolve channel path,
  stamp the timestamp, write the append-only message file, list a thread, list
  channels. Reads the message body from an argument or stdin; never composes it.
- `settings.json` → `permissions.allow` gains `Bash(~/.claude/hooks/handoff.sh:*)`.
- Propagate with `/install`.

## Portability

`hooks/handoff.sh` must run under macOS bash 3.2 as well as bash 4+. No
`${var,,}`, no `declare -A`, no `mapfile` — the same trap that felled
`dir-guard.sh`. Timestamps via `date -u +%Y-%m-%dT%H:%M:%SZ`.

## Acceptance

1. `/handoff send demo "hello"` then `/handoff read demo` prints `hello` with
   its `from`/`at` header.
2. `/handoff list` shows `demo` with a count of 1 and a last-activity time.
3. The mailbox lives under `~/.skadi/handoff/` and survives an `/install` run.
4. `/handoff send demo` with no message writes a baton note bearing the current
   branch and a pending-work summary.
5. `hooks/handoff.sh` runs clean under `/bin/bash` (3.2) — no `bad substitution`.

## Out of scope (YAGNI for v1)

- A local server / long-polling — rejected above.
- Read cursors / unread tracking — the whole short thread is shown each read.
- A `SessionStart` hook that announces unread channels — a possible later polish.
- Deleting or archiving channels — left to the user and the filesystem for now.
