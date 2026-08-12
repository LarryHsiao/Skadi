# Delegation — Dispatching Subagents

> Read before any Agent dispatch beyond a trivial lookup. This file is the full
> law; CLAUDE.md's *Delegation Discipline* section is the always-loaded core.
> Written plain, for any model tier to execute.

## When to delegate — and when not

Delegate when the work would flood the main context with material the
conclusion does not need:

- Reading more than ~3 files just to *find* something (scans, sweeps, audits).
- Repo-wide searches across many naming conventions or locations.
- Web research (multiple fetches, cross-checking sources).
- Batch mechanical edits across many files (one writer per seam — see below).
- Any verification of your own work (see *Verification* — the author never grades itself).

Do it yourself when:

- You already know the file, symbol, or value — a single Read/Grep is cheaper
  than any spawn.
- The task needs the conversation's context to do right, and briefing it whole
  would cost more than doing it (judgment calls mid-discussion, small edits in
  files already open).

## Model roster (as of 2026-08 — verify before relying; models rot)

Choose by capability first; the runtime-specific name is an implementation
detail. Verify the current roster before dispatch because aliases and
availability change independently in Claude Code and Codex.

| Tier | Claude example | Codex example | Use for |
|---|---|---|---|
| Mechanical | `haiku` | `gpt-5.6-luna` | Grep-style search, list reduction, structured extraction, format checks, batch application of an already-solved pattern. |
| Default worker | `sonnet` | `gpt-5.6-terra` | Implementation of a specified change, medium-depth research, rule-based code review, doc writing from an outline. |
| Strong judgment | `opus` | `gpt-5.6-sol` | Design trade-offs, broad refactors, resistant debugging, review where the specification itself may be wrong. |
| Highest available | `fable` when available | `gpt-5.6-sol` at the highest supported effort | Taste, ambiguity, architecture, and adversarial judgment. Spend deliberately. |

Rules of thumb:

- When `model` is omitted, the agent uses its role definition's model if one is
  set, otherwise inherits the session's. Name a *lighter capability tier*
  explicitly whenever the role does not need the session's tier; translate it
  to a model slug supported by the active runtime.
- Reasoning effort: inherited from the session. Some harness surfaces expose
  it per-call — when one does, use `low` for mechanical stages and the high
  tiers only for verify/judge stages; when none does, the model choice alone
  carries the tiering.
- The cheapest spawn is the one that does not happen; the next cheapest runs
  on Haiku.

## The dispatch triad — every delegation prompt carries all three

1. **Goal and why.** What to produce and why it matters — the subagent has not
   seen this conversation. Hand the text directly; never point it at a plan
   file or memory entry to "find its piece".
2. **Acceptance.** Observable outcomes that mark success — checkable, not
   vague. "Returns the list of files where X is defined, with line numbers",
   not "investigate X".
3. **Report format.** What shape the answer takes, and a size cap.

Templates for the five common shapes: `dispatch-templates.md`.

## Report contract

- Subagents return **conclusions plus `file:line` references** — never file
  dumps, never transcripts of what they read.
- A long artifact (a report, a generated file, a big diff) lands **on disk**;
  the reply carries its path and a three-line summary.
- A subagent that is blocked says so and names what it lacks. Answer plainly
  and re-dispatch — do not retry the same prompt at the same model and expect
  a different result.

## One writer per seam

Two implementation subagents on overlapping files race, and the merge is yours
to untangle. Read-only investigations parallelize freely; when uncertain
whether two tasks touch the same seam, dispatch them serially.

## Escalation ladder

| Situation | Action |
|---|---|
| Mechanical-tier agent fails once, with a sound brief | Re-dispatch at the default-worker tier. Do not iterate prompts at the mechanical tier. |
| Default-worker agent fails twice on the *same* subtask | Re-dispatch at the strong-judgment tier (or the session tier if higher), **carrying the full failure trail** — both attempts, their errors, what was already ruled out. |
| A hard subtask is solved and the same pattern repeats elsewhere | Push the solved pattern *down*: batch-apply at the mechanical/default-worker tier with the worked example in the prompt. |
| Two full rounds at the top available tier fail | Stop. Report the failure trail to the user; do not burn a third round. |

"Fails" means: wrong result, or blocked for reasons a better model would
resolve — *with the brief itself sound*. A flawed brief (missing information,
a wrong search pattern, an unstated constraint) is not a model failure: mend
the brief and re-dispatch at the **same** tier. Escalation fixes thin
capability, not bad instructions (`judgment.md` §2's negative example).

## Verification — the author never grades itself

- Acceptance is judged by a **fresh-context agent** that did not produce the
  work, or by a mechanical check (tests, a real run) that cannot flatter.
- Files written → a read-back: the verifier opens the files and confirms
  content matches the acceptance, not just that paths exist.
- Code changed → tests or a real run, per CLAUDE.md's *Implementation Loop*
  (fresh, same-turn).
- High-risk judgment calls (destructive actions, security-relevant findings,
  "is this bug real?") → a **second opinion**: an independent agent prompted
  to *refute* the conclusion. Two independent confirmations beat one confident
  author.
- When the main session did the work itself, the same rule holds: the
  Compliance Review (CLAUDE.md) is that fresh pair of eyes.
