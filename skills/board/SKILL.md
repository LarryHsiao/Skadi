---
name: board
description: Use when the user runs /board, /board add <KEY> [--active], /board remove <KEY>, /board refresh [--stability-scrape], /board stability-write <label> --from-json <file>, or /board list. A standing situation board served in the browser — one live page that gathers the tickets in progress (Jira status + AC rate from subtask completion), the metis growth pulse, and a Stability tile (crash-free users % by app, chosen from a live dropdown), each a tile that follows a JSON channel file on disk or, for Stability, a live fetch on demand. `/board` alone boots or reuses the server and prints the URL; `add` writes or refreshes a ticket channel; `remove` drops one; `refresh` re-fetches every ticket (the active hero preserved) and the growth numbers, and with `--stability-scrape` also sweeps every bound app's crash-free number, naming which ones need a Firebase-console scrape (the model then runs `/beleg`'s console flow and calls `stability-write` to persist what it found); `list` prints the channels. Data lives under ~/.skadi/board/; the writers, the manifest, and the page are hooks. Read-only against Jira, BigQuery, and the Crashlytics/GA4 exports — it never writes to the trackers.
purpose: Serves a live situation board of in-progress tickets and app growth in the browser.
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

### `/board refresh [--stability-scrape]`

    ~/.claude/hooks/board.sh refresh
    ~/.claude/hooks/board.sh refresh --stability-scrape

Re-fetches every ticket already on the board (preserving which one is active) and
the metis growth numbers. Growth is best-effort — a BigQuery hiccup skips it with
a note rather than failing the sweep.

Plain `refresh` never touches Stability — the live dropdown already covers any
app BigQuery can answer, in real time, with nothing to gain from pre-caching it.
`--stability-scrape` is the explicit ask to go further: it sweeps every bound
app's crash-free number and prints which ones BigQuery couldn't answer (no GA4
pairing, or the query itself failed). That printed list is yours to act on next
— see *The Stability tile* below for what to do with it. The hook stops at
naming the gap; it cannot drive Chrome itself.

### `/board list`

    ~/.claude/hooks/board.sh list

Prints the channels — tickets with status and AC (the active one starred), then
the growth line.

## The growth channel

`/board refresh` pulls growth alongside the tickets. To refresh growth alone,
`~/.claude/hooks/board.sh growth` runs the `/growth` hook, parses its headline
(WAU/MAU), copies the rendered dashboard in as the tile's Enter door, and writes
`growth.json`. Only metis has a GA4 → BigQuery export today.

## The Stability tile

Sits in the top strip, after Metis growth. Unlike every other tile it carries no
channel file — its dropdown and number are fetched live from the browser via two
routes `board-server.py` adds:

    GET /stability/apps            — the app roster, for the dropdown
    GET /stability/fetch?label=…   — one app's crash-free users %, on selection

Both shell out to `~/.claude/hooks/board-stability.py`, which builds the roster by
gluing two sources: every `crash_routing.md` any repo has ever bound via `/beleg`
(globbed across `~/.claude`, `~/.claude-personal`, `~/.claude-work`), layered with
hand-added or hand-corrected entries from `~/.skadi/board/stability-apps.json` —
the same "small local JSON you maintain by hand" pattern as
`ac-done-statuses.json`. **No `/board` verb manages it** — bind an app the normal
way, by running `/beleg` in its repo.

The percentage itself is a join: crashed users from the Crashlytics BigQuery
export, active users from GA4's. A `crash_routing.md` row now carries two optional
trailing fields — GA4 project · GA4 dataset — after the six `/beleg` already
writes (repo · flavor · Firebase project · bundle · platform · account); an app
bound without them shows in the dropdown but reads "GA4 not configured for this
app" instead of a percentage, rather than guessing at a denominator it doesn't
have.

**Fetched on pick, not on the poll loop.** The roster loads once per page load;
selecting an app fires one live query. Neither auto-refreshes — a live BigQuery
join is not something to run every 8 seconds, and a newly-bound app needs a page
refresh to appear.

### The console-scrape fallback

When BigQuery can't answer for an app — no GA4 pairing, or the query itself
failed — `refresh --stability-scrape` names it rather than leaving the tile to
show "GA4 not configured" forever. For each app it lists:

1. Read the printed `project` / `bundle` / `platform` / `account` and follow
   `/beleg`'s own console-scrape flow (`skills/beleg/SKILL.md` §3) — the same
   navigation, the same account-index care — but read the dashboard's
   **"Crash-free users %" headline** directly, rather than the issue list
   `/beleg` ranks. No BigQuery export is needed for this number; the console
   computes it internally.
2. Write what was found — a percentage, or `null` with a `note` if the console
   itself showed nothing usable — to a scratch JSON file:
   `{"crash_free_pct": 93.1, "note": null}`.
3. Persist it:

       ~/.claude/hooks/board.sh stability-write "vitallink-ca · jp · ANDROID" --from-json /tmp/scrape.json

   This writes `stability-<slug>.json` (the label, lowercased and dashed) as an
   ordinary pulled channel — same auto-pickup as every other tile, no live
   endpoint involved.

The live dropdown reads this channel as its fallback whenever a BigQuery fetch
comes back with no percentage: it shows the pulled number in its place, no
label marking it as scraped or stating its age — a decided simplification
(`docs/plans/board-stability-console-fallback.md`), not an oversight. If both
BigQuery and the fallback channel have nothing, the tile still shows the
BigQuery note plainly.

**This step needs a live, Chrome-connected model turn.** `--stability-scrape`
only ever *names* the gap — a hook cannot drive Chrome, so an unattended
`refresh --stability-scrape` (cron, `/loop`, a background sweep) will print the
needs-scrape list into a log no one reads and go no further. Run it
interactively, or don't pass the flag.

## Notes

- **Auto-pickup, not auto-fetch.** The page auto-shows any channel *file* change
  within a poll (~8 s). It does **not** poll Jira or BigQuery — fresh numbers are a
  pull: run `add`/`refresh`. A scheduled `refresh` (via `/loop` or cron) closes
  that gap when wanted. The Stability tile is a further exception — see above.
- **One server, one fixed port.** `serve` binds port 10000 (override with
  `BOARD_PORT`) and reuses it whenever it still answers, rather than
  multiplying servers — the URL never drifts across restarts. The handbook
  rides the same server: `board-server.py` routes `/handbook/` and
  `/previews/` straight to the skadi repo root, so `./handbook.sh` and the
  board's own "Handbook ↗" link both resolve through this one port.
- **Read-only.** The board reads Jira, BigQuery, and the Crashlytics/GA4 exports;
  it never writes to a tracker.
- **Tests ride beside the hooks** — `board-ticket.test.sh`, `board-growth.test.sh`,
  `board-manifest.test.sh`, `board-server.test.sh`, `board-stability-write.test.sh`
  run offline via injected fixtures; `test_board_stability.py` covers
  board-stability.py's own logic the same way `test_beleg_crashes.py` covers
  beleg's. The console scrape itself stays unverifiable offline, same caveat
  `docs/plans/beleg-crash-analysis.md` already carries for beleg's own fallback.
