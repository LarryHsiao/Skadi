# Adherence Pulse (`/estë`) — Design

- **Date:** 2026-07-09
- **Status:** Design approved; ready for implementation plan.
- **Working name:** `estë` (Estë, the Vala of healing and rest — the pulse measures the *health* of the workflow). Provisional; may be renamed.

## Purpose

A **standing health pulse** over how faithfully the skadi config — its CLAUDE.md
rules and its skills — is actually followed in daily use. Watched over time so a
change to the config shows its effect: did rewording a rule lift its adherence,
did a skill grow more or less reliable. The value is turning *"I think the gauge
gets skipped sometimes"* into *"the gauge appeared on 71% of free-form turns across
50 sessions, trending up since the last edit."*

The trap it must avoid is a single blended percentage. The honest shape is a
**per-item scorecard, each row carrying its own confidence tier** — never one number
that averages a certain signal with a shaky one.

## What it measures (first cut)

Markers only — deterministic traces and structural markers. **No LLM judge in the
first cut**; a model-graded deep-dive is a clearly-labelled later slice.

Two kinds of signal, both with an honest denominator:

1. **Workflow completion** — per skill: denominator = invocations, numerator =
   the skill's terminal verdict token appearing in the run that followed.
2. **Grammar rate** — denominator = user messages, numerator = messages that drew
   no `> **Grammar:**` correction.

Two more rule signals are **defined in the rubric but marked `pending`** in the
first cut, because their denominator lives outside the transcript (a git-log or
forge probe): **commit-footer present** and **PR/MR assignee set**. The rubric
stays complete and honest; the engine skips `pending` items with a note until
their probe is built (second slice).

## Transcript scope

All configured roots. The engine walks `projects/**/*.jsonl` under each of
`~/.claude`, `~/.claude-personal`, `~/.claude-work` — the true picture of how the
config performs across every project, not only while editing skadi itself.

## Non-goals (YAGNI)

- No LLM/semantic grading in the first cut (later slice, labelled as estimate).
- No ambient-rule scoring (gauge/acceptance/surgical-changes) whose denominator
  requires guessing which turns were "free-form actions" — deferred.
- No auto-discovery of every skill; the first rubric curates a handful with known
  verdict tokens.
- Never writes to a tracker or a repo. Read-only over transcripts (and, later,
  read-only over git log).

## Architecture

Three parts, mirroring the growth/board separation of engine, data, and page.

| Component | Role |
|---|---|
| `hooks/pulse-rubric.json` | **Data** — the declarative matcher table. One entry per measured item. |
| `hooks/pulse-scan.py` | **Engine** — walks every root's `projects/**/*.jsonl`, applies each rubric entry, computes per-item `{applied, complied, rate, tier}`, appends the run to history, writes the current snapshot. |
| `hooks/pulse-page.html` + `skills/estë/SKILL.md` | **Presentation** — renders the Henneth dashboard from history (headline rate, per-item table, trend sparkline, week/month deltas). A `board.sh pulse` channel writer lays a compact board tile that links to the full page. |

### Rubric entry schema

```json
{
  "id": "workflow.glorfindel",
  "label": "Glorfindel completes",
  "kind": "workflow",
  "tier": "structural",
  "applies": "<command-name>/glorfindel</command-name>",
  "complied": "\\b(STIRRED|QUIET)\\b",
  "denom": "invocations"
}
```

- `id` — stable key, used in history and the scorecard.
- `label` — human row title.
- `kind` — the matcher type (below). Selects how `applies`/`complied` are read.
- `tier` — confidence tier: `deterministic` | `structural` | (later) `semantic`.
  Rendered per row so a shallow signal never masquerades as a deep one.
- `applies` — matcher for the **denominator** event.
- `complied` — matcher for the **numerator** event.
- `denom` — names the denominator unit for the reader (`invocations`, `messages`).

### Matcher kinds (first cut)

- **`workflow`** — denominator: count of `applies` matches (a skill invocation) in
  a session. The invocation marker for the first cut is the user-typed slash form —
  the `<command-name>/skill</command-name>` tag in a user turn; programmatic Skill-tool
  invocations are not counted in v1 (they are rare for the curated user-facing skills
  and would blur the denominator). Numerator: a `complied` regex (the skill's verdict
  token) appearing in the assistant turns of that invocation's run, bounded by the
  next user turn or the next skill invocation. One row per skill.
- **`grammar`** — denominator: user messages. Numerator: user messages **not**
  followed by a `> **Grammar:**` line in the next assistant turn. `tier:
  deterministic`.
- **`git-probe` / `forge-probe`** — `pending` in the first cut. Their denominator
  comes from a git-log scan / forge query, not the transcript. Defined so the rubric
  reads whole; engine emits `status: "pending"` and skips computation.

## Data flow and storage

```
all roots  projects/**/*.jsonl ──▶ pulse-scan.py ──┬─▶ ~/.skadi/pulse/history.jsonl   (append one line per scan → trend)
              (read-only)                           └─▶ ~/.skadi/pulse/pulse.json       (current snapshot = board channel)
                                                             │
                                     Henneth dashboard ◀─────┘ (reads history.jsonl for the trend)
```

- **History** — `~/.skadi/pulse/history.jsonl`, one line per scan run:
  `{ts, window, items: [{id, applied, complied, rate, tier, status}], byTier}`.
  Append-only; the trend is derived from it.
- **Snapshot** — `~/.skadi/pulse/pulse.json`, the board channel: headline rate,
  each item's current figures, and week-over-week deltas.
- **Window** — default the last **30 days** (override with a flag/env), so a scan
  need not re-read all of history each run.
- `ts` is stamped by the caller (the skill/hook) and passed into the engine, since
  workflow scripts cannot call `Date.now()`; `pulse-scan.py` is a plain script and
  may stamp its own, but the design keeps the stamp injectable for testability.

## Cadence and invocation

On demand, with optional scheduling — the growth/board pattern.

- `/estë` (the skill) scans, appends to history, writes the snapshot, re-lays the
  dashboard, prints the Henneth URL.
- For a standing cadence, the user wraps it in `/loop` or a cron — the skill itself
  arms nothing.
- `board.sh pulse` refreshes the board tile from the latest snapshot.

## Error handling

- A torn or oversized JSONL line → skipped, with a one-line stderr note (as
  `board-manifest.py` does) so nothing vanishes silently.
- A configured root that does not exist → skipped silently.
- No history yet → the dashboard shows a "first run" empty state.
- A rubric entry whose matcher raises → that item is marked `status: "error"`;
  the others are unaffected (fail-soft per item, loud per item).
- `pending` items render greyed with a "probe not built" note, not a zero.

## Testing

- `hooks/pulse-scan.test.sh` — offline, driven by an injected fixture transcript
  directory (a `PULSE_ROOTS` env seam, mirroring `BOARD_DIR`). Assert per-item
  `applied` / `complied` / `rate` for:
  - a skill **invoked and completed** (verdict token present) → 1/1,
  - a skill **invoked but not completed** (verdict absent) → 0/1,
  - grammar **with and without** a correction,
  - a **torn line** skipped without derailing the scan,
  - a `pending` item emitting `status: "pending"`, not a computed rate.
- Rubric is data → a small schema check (every entry has the required keys; `kind`
  is known; `tier` is legal).
- Tests follow the repo convention: name the expected value first, then compare.

## Later slices (out of first-cut scope, but the seams are laid)

1. **Git/forge probes** — build the `git-probe` / `forge-probe` engines so the
   `pending` rows compute (commit-footer, PR/MR assignee).
2. **Model-judge** — a new `kind: semantic`, `tier: semantic`: an LLM grades a
   sampled subset of turns for depth (was a present acceptance actually met). Runs
   less often; its rows are labelled as estimates with the judge's error bar.
3. **Ambient rules** — gauge / acceptance / surgical-changes, once a defensible
   heuristic for the "free-form action" denominator is chosen; flagged approximate.
4. **Skill auto-discovery** — generate `workflow.*` rows for every skill rather
   than a curated set.
