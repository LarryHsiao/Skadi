---
name: board
description: Use when the user runs /board, /board add <KEY> [--active], /board remove <KEY>, /board refresh, or /board list. A standing situation board served in the browser — one live page that gathers the tickets in progress (Jira status + AC rate from subtask completion) and the metis growth pulse, each a tile that follows a JSON channel file on disk. `/board` alone boots or reuses the server and prints the URL; `add` writes or refreshes a ticket channel; `remove` drops one; `refresh` re-fetches every ticket (the active hero preserved) and the growth numbers; `list` prints the channels. Data lives under ~/.skadi/board/; the writers, the manifest, and the page are hooks. Read-only against Jira and BigQuery — it never writes to the trackers.
user_invocable: true
---

# Board

The situation board — one standing window onto the work: the tickets in progress
and the app's growth, gathered where a glance can hold them. Each source is a
**channel** — a JSON file under `~/.skadi/board/`. The page polls the folder every
few seconds; a channel added, changed, or removed shows on its own, no rebuild.

All work routes through one entry, `~/.claude/hooks/board.sh`, which orchestrates
focused helpers (the ticket writer, the growth writer, the shared manifest, the
page). Run the verb the user named.

## Verbs

### `/board` — serve

    ~/.claude/hooks/board.sh serve

Lays the page and theme into `~/.skadi/board/`, boots a background server (or
reuses the one the lockfile names, if it still answers), and prints the URL.
Surface the URL inline; tell the user the tiles follow the channel files.

### `/board add <KEY> [--active]`

    ~/.claude/hooks/board.sh add PSG-4478 --active

Fetches the Jira ticket and its subtasks, derives the AC rate from subtask
completion (a subtask counts *met* when its status is a `done` category **or** a
name listed in `~/.skadi/board/ac-done-statuses.json` — the team's done-enough
set), and writes `ticket-<KEY>.json`. `--active` makes it the hero and clears the
flag on every other ticket, so exactly one hero stands. Re-running refreshes it.

**Tracker routing.** Before dispatching, resolve the tracker from the key's
project prefix via the `tracker_routing` memory (e.g. `MET → youtrack`,
`PSG → jira`), the same map `/council` and `/glorfindel` use. Default to
`jira` when the prefix is unmapped. Pass it through:

    ~/.claude/hooks/board.sh add MET-1 --active --tracker youtrack

`board.sh add` forwards all arguments to the ticket writer, so `--tracker`
reaches it unchanged. On `refresh`, the tracker is re-derived from each
channel's recorded `source` — no memory lookup needed.

### `/board remove <KEY>`

    ~/.claude/hooks/board.sh remove PSG-4478

Drops the ticket channel and regenerates the manifest. The tile vanishes on the
next poll.

### `/board refresh`

    ~/.claude/hooks/board.sh refresh

Re-fetches every ticket already on the board (preserving which one is active) and
the metis growth numbers. Growth is best-effort — a BigQuery hiccup skips it with
a note rather than failing the sweep.

### `/board list`

    ~/.claude/hooks/board.sh list

Prints the channels — tickets with status and AC (the active one starred), then
the growth line.

## The growth channel

`/board refresh` pulls growth alongside the tickets. To refresh growth alone,
`~/.claude/hooks/board.sh growth` runs the `/growth` hook, parses its headline
(WAU/MAU), copies the rendered dashboard in as the tile's Enter door, and writes
`growth.json`. Only metis has a GA4 → BigQuery export today.

## Notes

- **Auto-pickup, not auto-fetch.** The page auto-shows any channel *file* change
  within a poll (~8 s). It does **not** poll Jira or BigQuery — fresh numbers are a
  pull: run `add`/`refresh`. A scheduled `refresh` (via `/loop` or cron) closes
  that gap when wanted.
- **One server, reused.** `serve` reuses the port in `~/.skadi/board/.board-port`
  when it still answers, rather than multiplying servers.
- **Read-only.** The board reads Jira and BigQuery; it never writes to a tracker.
- **Tests ride beside the hooks** — `board-ticket.test.sh`, `board-growth.test.sh`,
  `board-manifest.test.sh` run offline via injected fixtures.
