# Board — YouTrack ticket support

**Date:** 2026-07-08
**Status:** approved, pre-implementation

## Problem

The situation board's ticket writer, `hooks/board-ticket.sh`, reaches **only Jira**
— it fetches Jira REST v3, resolves `jira` credentials, and stamps
`source: "jira"`. Projects that live on YouTrack (e.g. `MET`, per the
`tracker_routing` memory) cannot be seated on the board: `/board add MET-1`
would hit Jira with a YouTrack key and fail the fetch.

## Goal

Let the board seat YouTrack tickets alongside Jira ones, with the same tile —
status, AC rate from subtask completion, blocked flag, Enter door — routed by
the key's project prefix so no extra typing is needed.

## Approach — normalize then share

Each tracker owns a **fetch + normalize** step that emits a uniform intermediate
issue JSON; one **shared shaper** builds the channel from that intermediate; the
**common tail** (hero-clearing, manifest) is untouched. Tracker differences are
isolated to the normalize step. The existing `board-ticket.test.sh` Jira fixture
guards the Jira path through the refactor.

Rejected alternatives:
- *Parallel branches* — keeps the Jira shape verbatim but duplicates the AC/roster
  math across two jq blocks.
- *Separate writer files* — mirrors the council fetch pair but adds two hook files
  and duplicates the shared tail.

## The normalized intermediate

```json
{
  "id": "MET-1",
  "title": "…",
  "status": "In Progress",
  "statusCategory": "",
  "type": "Bug",
  "priority": "Normal",
  "url": "https://…/issue/MET-1",
  "source": "youtrack",
  "subtasks": [
    { "id": "MET-2", "title": "…", "status": "Fixed", "done": true }
  ]
}
```

The intermediate carries the parent's `statusCategory` directly, so the page's
hero logic (`t.statusCategory === "done"`) works unchanged for both trackers.
The parent's `statusCategory` comes from the **tracker's own done signal** — the
raw category key for Jira, `"done"` when `resolved != null` for YouTrack. The
`ac-done-statuses.json` name-override applies to **subtasks only** (the AC rate),
not to the parent — mirroring the board's existing Jira behaviour, so both
trackers treat the parent the same way. (A parent that is "done-enough" by state
name but not by the tracker's own signal therefore reads as not-done at the hero
level — a narrow case, kept consistent across trackers by design.)

## Components

### `hooks/board-ticket.sh` — router + shared shaper

- New option `--tracker <jira|youtrack>`, **default `jira`** (back-compatible).
- Parse `<KEY> [--active] [--tracker T]` (flags order-independent).
- Route to the tracker's fetch+normalize; run the shared shaper jq to write
  `ticket-<KEY>.json`; then the existing hero-clear (python) and
  `board-manifest.py` tail, unchanged.
- Shared shaper computes AC (`met`/`total`/`pct`, `pct` null when `total == 0`),
  `blocked` (status name matches `block`), `statusCategory` from `done`, and
  copies `id/title/status/type/priority/url/source/subtasks/active/updated`.

### Jira fetch + normalize

- Fetch unchanged: `GET /rest/api/3/issue/<KEY>?fields=summary,status,issuetype,priority,subtasks`.
- Normalize jq maps Jira fields to the intermediate: `done` = `statusCategory.key == "done"`
  OR status name in the done-set; each subtask likewise.

### YouTrack fetch + normalize

- Fetch: `GET /api/issues/<id>?fields=idReadable,summary,resolved,customFields(name,value(name)),links(direction,linkType(name),issues(idReadable,summary,resolved,customFields(name,value(name))))`.
- Auth: Bearer token via `secret.sh youtrack` (uri + token), mirroring
  `council-youtrack-fetch.sh`. Non-ASCII safety via `--slurpfile`/`--rawfile`.
- Normalize jq:
  - `status` = the `State` customField's `value.name`.
  - `done` = `resolved != null` **OR** State name in the done-set.
  - `type` = `Type` customField, `priority` = `Priority` customField.
  - `subtasks` = `links` where `linkType.name == "Subtask"` and
    `direction == "OUTWARD"` (this issue is the parent), flattened; each subtask's
    `done` derived the same way (`resolved != null` OR State in done-set).
  - `url` = `<base>/issue/<id>`, `source: "youtrack"`.

### done-set (`ac-done-statuses.json`)

Reused as-is for both trackers, matched by status **name** (case-insensitive).
For YouTrack the primary done signal is `resolved`; the name-set is the secondary
"done-enough" override, exactly as Jira uses it.

### `/board` skill routing

- `add`: the skill resolves the tracker from the key's prefix via the
  `tracker_routing` memory (MET→youtrack, PSG→jira), same as `/council` and
  `/glorfindel`, and passes `--tracker` to `board-ticket.sh`.
- `refresh`: `board.sh` reads each channel's recorded `.source` and passes it
  back as `--tracker`, so refreshes stay on the right tracker with no memory
  lookup. (Update the `refresh` loop in `hooks/board.sh` accordingly.)

## Error handling

The writer is an action, so it throws (non-zero exit + error line) on a failed
fetch or missing credentials — matching the current Jira behaviour. `board.sh
refresh` already tolerates a per-ticket failure without aborting the sweep.

## Testing

`board-ticket.test.sh` extends the `BOARD_TICKET_ISSUE_FILE` seam to carry the
tracker (a companion `BOARD_TICKET_TRACKER`, default `jira`), so a raw response is
injected and the real normalize runs offline:

- **Existing Jira fixture** stays green through the normalize refactor (parent +
  subtasks → AC, source `jira`, browse URL).
- **New YouTrack fixture** — a parent with two `Subtask`/`OUTWARD` links, one
  `resolved` and one not → channel shapes to `source: "youtrack"`, `ac.pct == 50`,
  `ac.met == 1`, `ac.total == 2`, and `url` = `<base>/issue/<id>`.
- **YouTrack no-subtasks** — a parent with no Subtask links → `ac.pct == null`.

## Non-goals

- No new tracker beyond Jira and YouTrack.
- No change to the page, growth, sweep, or henneth channels.
- No auto-detection or heuristic fallback — routing is by prefix only.
