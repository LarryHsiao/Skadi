---
name: estë
description: Use when the user runs /estë. Computes the adherence pulse — a marker-based, per-item scorecard (with confidence tiers) of how faithfully the skadi config's rules and skills are followed across all config roots — appends the run to history, renders a Henneth dashboard, and prints its URL. Read-only over transcripts; never writes to a tracker or repo. Runs on demand; wrap in /loop or cron for a standing cadence.
user_invocable: true
---

# Estë — The Adherence Pulse

Estë, the Vala of healing and rest, measures the health of the work: how
faithfully the config's rules and skills are kept. One run scans every config
root's transcripts, scores each rubric item, and lays a dashboard in the Henneth
window.

## Run

    python3 ~/.claude/hooks/pulse-scan.py

This walks `~/.claude`, `~/.claude-personal`, `~/.claude-work` under
`projects/**/*.jsonl` (read-only), appends a line to `~/.skadi/pulse/history.jsonl`,
writes the board channel `~/.skadi/board/pulse.json`, and renders
`~/.claude/previews/henneth/adherence-pulse.html`. It prints the headline overall.

Then ensure the Henneth window is up (boot it with `/henneth` if not) and surface
the dashboard URL inline — the page follows the folder, so the pulse appears on its
own once rendered.

## Notes

- **Read-only.** The pulse reads transcripts; it never writes to a tracker or repo.
- **Markers only.** The first cut scores machine-checkable signals — per-skill
  completion and grammar rate. Two rule items (commit-footer, PR assignee) are
  defined but marked `pending` until their git/forge probes are built.
- **Subagent verdicts under-report.** A skill that posts its verdict through a
  subagent — `/council`'s `[COUNSEL]`, `/celebrimbor`'s `[GWAITH]` — writes that
  marker in the tracker, not the main-thread transcript the pulse reads, so those
  rows read low. A known first-cut limitation, not a failure of the skill.
- **Compliance Review bills per task segment, not per prompt turn.**
  `rule.compliance-review` folds consecutive mutating runs (the user steering
  between edits) plus their read-only wind-down into one segment — CLAUDE.md
  owes the review once per task, "before the done report", not after every
  turn that touched a file. Known trade-off: two tasks back-to-back with no
  read-only run between them merge and bill once. A `since` date on the
  rubric entry drops runs from before the rule existed. A segment closing with
  an explicit `Compliance Review: SKIPPED (reason: …)` is excluded from both
  sides — a reasoned waiver is no silent omission — and its count stands beneath
  the row, so the exclusion is named rather than hidden.
- **Compliance Review requires delegation evidence, not just the closing line.**
  A segment only complies when an `Agent` tool call appears at or before the
  turn bearing `Compliance Review: PASS|FAIL` (which itself must follow the
  segment's last mutating turn) — the literal marker alone no longer
  suffices, since a model could type it unearned without ever spawning the
  review agent CLAUDE.md calls for. The Agent lookup spans the whole
  segment: CLAUDE.md's order is review, then fix the findings (more mutating
  turns), then verify, then the verdict, so the Agent call routinely
  precedes the segment's last edit.
- **`review.verdict` reads the outcome, not the ritual.** Where
  `rule.compliance-review` asks whether the review was performed at all, this
  row asks how the reviews that *were* performed came out: the rate is PASS
  over PASS + FAIL. Its denominator counts only segments carrying real review
  evidence — the verdict line after the last edit, with an `Agent` dispatch
  behind it, the same proof `_segment_complies` demands. A segment that closed
  silently, or with a verdict no agent backs, is neither credited nor
  penalized: a review never run is no verdict on the work. That excluded
  population is reported beneath the row rather than hidden, split into silent
  and explicitly `SKIPPED`. The heuristic tier is owed to the segment fold, not
  the marker — the fold merges two back-to-back tasks with no read-only run
  between them.
- **First-shot rate measures the model, not a rule.** `model.first-shot` asks a
  different question from every other row: not "did the model keep the config's
  rule" but "how good is the model" — what fraction of task segments landed
  without the user coming back to correct it. Within a segment (the same task
  fold `rule.compliance-review` uses), a *rework* run is a mutating run after
  the first whose opening prompt reads as a correction (`rework` regex — "no,
  the arrow points left"; both English and Chinese cues). An *additive*
  follow-up ("also commit and push") is progress, not a miss, and does not
  count. A segment is first-shot when its rework count stays within
  `threshold` (default 0 — strict). Read the `byModel` split, not the overall
  rate: the point is comparing Opus / Sonnet / Fable. The tone regex is a
  keyword heuristic — a mixed-language or oddly-phrased correction can slip it,
  so the row reads slightly optimistic; it sits in the heuristic tier for that
  reason.
- **Success/failure is one click away.** Every rubric item carries a plain-language
  `criterion` — what counts as a pass, what counts as a miss (✓ … · ✗ …). On the
  dashboard each row bears an ⓘ button; clicking it unfolds the criterion beneath
  the row, clicking again folds it. The text is the single source: it lives on the
  rubric entry, flows into the page's data, and reads the same as this skill's notes.
- **Honest tiers.** Each item carries a confidence tier, and the headline shows a
  figure per tier; a single cross-tier average is shown too, but always labelled as
  such and never standing alone.
- **Standing cadence.** The skill arms nothing. For a recurring pulse, wrap it:
  `/loop 6h /estë`, or a cron.
- **Tests ride beside the hook** — `pulse-scan.test.sh` runs offline via injected
  fixture roots (`PULSE_ROOTS`).
