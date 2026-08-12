---
name: este
description: Use when the user runs /este. Computes the adherence pulse — a marker-based, per-item scorecard (with confidence tiers) of how faithfully the skadi config's rules and skills are followed across all config roots — appends the run to history, renders a Henneth dashboard, and prints its URL. Read-only over transcripts; never writes to a tracker or repo. Runs on demand; wrap in /loop or cron for a standing cadence.
purpose: Computes an adherence pulse scoring how faithfully the skadi config's rules and skills are kept.
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
`~/.skadi/henneth/adherence-pulse.html`. It prints the headline overall.

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
- **Compliance Review requires a reviewer's filed verdict, not just the closing
  line.** A segment only complies when a review agent filed its own
  `Compliance Review: PASS|FAIL` within that segment, at or before the turn
  bearing the closing marker (which itself must follow the segment's last
  mutating turn). The literal marker alone does not suffice — a model could
  type it unearned. Neither does a bare `Agent` tool call, which this check
  once accepted: an unrelated Explore search satisfied it as readily as a
  review did, and one credited segment in five sat in a session that had filed
  no verdict at all. The window opens at the segment's start rather than its
  last edit, because CLAUDE.md's order is review, then mend the findings (more
  mutating turns), then verify, then the verdict — so the review routinely
  precedes the segment's last edit.
- **`review.verdict` traces the FINAL result, not the reviewer's first draft.**
  Where `rule.compliance-review` asks whether the review was performed at all,
  this row asks how sound the work that shipped actually was: the rate is
  (PASS, or FAIL judged mended) over every Compliance Review agent dispatched.
  The verdict is still read from the reviewer's own transcript
  (`<session>/subagents/agent-*.jsonl`), never the thread's closing line — the
  thread never writes FAIL, since CLAUDE.md's order is review, then mend the
  findings, then report, so scoring that line would ask the summarizer to
  grade itself and could only ever read 100%. But a raw FAIL is not the same
  question as a *sound outcome*: a finding that gets fixed before the report
  is the review doing its job, not a miss against it. So a FAIL folds back in
  as compliant once a mend-judge — reading the reviewer's own findings beside
  what the segment did afterward, cached in `mend-verdicts.json` — calls it
  `mended`; one it calls `unmended`, or one it could not reach at all, stays a
  miss. `review.recovered` isolates that FAIL population on its own and names
  the recovery rate this row folds in but does not show by itself. A mutating
  segment that closed with no review behind it is neither credited nor
  penalized: a review never run is no verdict on the work. That excluded
  population is reported beneath the row rather than hidden, split into
  silent and explicitly `SKIPPED` — counted per segment, where the rate itself
  counts reviews, since one task may draw several audits or none. Three
  approximations hold it in the heuristic tier: the segment fold behind that
  excluded count, `byModel` attributing a review to the model that authored
  the *session* under review rather than the run, and the mend-judge's own
  call on whether a FAIL's findings were actually addressed.
- **`review.recovered` is the FAIL-only twin: of the reviews that misfired, how
  many were caught and fixed?** review.verdict's final-result framing means a
  low number there does not, by itself, distinguish "reviews are working —
  findings get fixed" from "findings are shipping unfixed." This row answers
  that directly: applied is every FAIL located inside a task segment (one
  outside any segment — a review dispatched during a purely read-only run,
  before any edit exists to mend — has nothing to show a mend in, and is
  absent rather than guessed at); complied is the ones the same mend-judge
  calls `mended`. A FAIL the judge could not reach is excluded from both sides
  and named beneath the row as `unjudged`, the same discipline as
  `plan.accepted`'s abandoned count. Heuristic tier for the same reason
  `plan.accepted` and `plan.bug-reported` are: the call is a model's judgment,
  cached per review so a closed transcript is never re-judged.
- **`plan.bug-reported` names each completion by its request, and its rate leans
  high.** The row asks whether a finished piece of work drew a bug report later in
  the same session, so a *high* rate is the good reading. Two things shape it.
  First, a task segment opens at its *mutating* run, and under the Free-Form Gate
  that is the run the user's assent begins — so a completion's own opening prompt
  is "proceed", which no judge can pin a later bug report to. The candidate list
  therefore describes each completion by the request standing before the gauge,
  which is what the gate proposed. Second, a report the judge calls a real bug but
  cannot pin to any candidate is dropped rather than guessed at, and the
  completion it silently described stays counted clean — so the rate reads high by
  up to the unattributed count, which stands beneath the row rather than hiding
  behind the ⓘ. Both approximations hold the row in the heuristic tier.
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
  `/loop 6h /este`, or a cron.
- **Tests ride beside the hook** — `pulse-scan.test.sh` runs offline via injected
  fixture roots (`PULSE_ROOTS`).
