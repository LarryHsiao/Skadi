# The `[MELLON]` start gate — opt-in entry to the skeleton-stage pipeline

**Date:** 2026-06-09
**Status:** Design approved, awaiting spec review
**Builds on:** `docs/superpowers/specs/2026-06-08-skeleton-stage-design.md`

## Purpose

The skeleton-stage pipeline today drafts a plan for **any** ticket a sweep's
`--filter` matches: the decider's final branch returns `draft_plan` unconditionally
when no `[PLAN]` exists (`hooks/skeleton-rung.py:82`). A project full of open tickets
would have plans drafted for all of them on the first `/loop` tick.

This adds an **opt-in entry gate**: the agent drafts a plan only after the human
(Elrond) posts a start word on the issue. The word is `[MELLON]` — the password to
the Doors of Durin, which Celebrimbor himself wrought; the smith's own door-password
opens the pipeline he forges at its end. The plain alias is `[START]`.

## The governing principle

> **Every agent step is preceded by a human go-ahead.**

Today two of the three agent steps are gated by an `[FORTH]` (plan→skeleton,
skeleton→forge); the first — plan drafting — is not. `[MELLON]` closes that gap. It
is an **entry** token, not a third approval: it fires at the front, when nothing has
been produced yet and there is nothing to approve. `[FORTH]` remains the **approval**
token that blesses a produced artifact onward. Two kinds of gesture, kept distinct.

The full arc, three human gestures unlocking three agent steps:

```
Elrond: [MELLON]   →  agent drafts  [PLAN]
Elrond: [FORTH]    →  agent draws   [SKELETON] + PNG
Elrond: [FORTH]    →  agent forges  the draft PR + [GWAITH]
```

## Scope

- **YouTrack only**, matching the skeleton-stage flow it extends. The Jira path
  (append `[COUNSEL vN]`) is untouched.
- **One new derivation** (`await_start`) and **one guarded line** in the decider. No
  new hook, no new permission, no YouTrack field or tag — the thread stays the record.

Out of scope: a YouTrack tag/state as the signal (rejected — reintroduces the field
dependency the skeleton-stage design deliberately avoided); making a bare `[FORTH]`
double as a start signal (rejected — see *Deliberate strictness*).

## The gate — a fifth rung ahead of the rest

A pre-plan **Dormant** state joins the gate table ahead of all others. Every existing
row is unchanged.

| Condition on the thread | Rung — who owes |
|---|---|
| no `[PLAN]`, no `[MELLON]` | **Dormant** — human owes the start word |
| no `[PLAN]`, `[MELLON]` present | **PlanReady** — agent drafts the plan |
| `[PLAN]`, no `[FORTH]` past its watermark | PlanReady — human owes a verdict |
| `[FORTH]` past plan, no `[SKELETON]` | Skeleton — agent owes work |
| `[SKELETON]`, no `[FORTH]` past its watermark | SkeletonReady — human owes a verdict |
| `[FORTH]` past skeleton, no `[GWAITH]` | Coding — agent owes work |
| `[GWAITH]` present | Done |

`[MELLON]` is detected exactly as `[FORTH]` is: any **human** comment (login ≠
`BOT_LOGIN`) whose text bears the token, case-insensitive, with `[START]` as the
plain alias. It is checked for **presence only** — no watermark relation — because it
is an entry gate that fires before any artifact exists. Once a `[PLAN]` is on the
thread, `[MELLON]` no longer matters; the flow proceeds by watermark and `[FORTH]` as
before.

## Where the gate lives — the decider (uniform)

The gate lives in `skeleton-rung.py`, the single source of truth the whole pipeline
already routes through. Both the unattended sweep **and** a direct, manual
`/council youtrack:<id>` respect it: a ticket with no `[PLAN]` and no `[MELLON]`
yields `await_start` (a no-op) for every caller.

This was chosen over a sweep-only gate (where a manual `/council` would still draft
immediately) for one source of truth — entry logic in one place, not split between
the sweep skills and the decider.

## The decider change — `hooks/skeleton-rung.py`

A single guarded line. The unconditional final return —

```python
return out("draft_plan")
```

becomes:

```python
has_mellon = any(_is_mellon(c.get("text", "")) for c in humans)
return out("draft_plan") if has_mellon else out("await_start")
```

plus a `_is_mellon()` twin of `_is_forth()` and a `START = ("[MELLON]", "[START]")`
module constant mirroring `VERDICT`. The new action `await_start` joins the action
vocabulary. Everything below the `if plan:` branch is unchanged — this is the only
edit to `decide()`.

### Deliberate strictness

A bare `[FORTH]` on a planless ticket does **not** open the gate; only
`[MELLON]`/`[START]` does. There is nothing to approve before a plan exists, so an
`[FORTH]` there is meaningless. Keeping the openers distinct avoids a confusing back
door (a stray approval silently starting work no one asked to begin).

## The skills

| Skill | Change |
|---|---|
| `/council` (YouTrack path) | `await_start` joins the no-op family with its own report line: *"dormant — awaiting `[MELLON]`."* Never drafts a plan for an un-opened ticket. |
| `/aule`, `/glorfindel` | Rung-dispatch table gains `await_start → skip`; the closing report carries a tally: *"N ticket(s) await `[MELLON]` — dormant until opened."* Dropped from the work manifest, surfaced as a count. |

The dormant tally is a deliberate, narrow divergence from the skeleton-stage rule
that no-op tickets *"are dropped from the manifest silently"* — a count guards against
a backlog of un-opened tickets looking identical to an empty project, without the
wall of rows a per-ticket listing would bring.

## Testing

- **Unit, automated** — `tests/test_skeleton_rung.py`. The existing
  `test_empty_thread_drafts_plan` **changes meaning**: an empty thread now yields
  `await_start`, not `draft_plan`; it is renamed (`test_empty_thread_awaits_start`)
  and its `expected` updated. Two new tests land:
  - `test_mellon_drafts_plan` — a human `[MELLON]` comment, no `[PLAN]` → `draft_plan`.
  - `test_start_alias_drafts_plan` — the `[START]` alias → `draft_plan`.

  The seven downstream tests each carry a `[PLAN]`, so they never reach the gated
  branch and stand as-is. No network.
- **End-to-end, manual** — on a YouTrack sandbox issue (`MET-1`), confirm: a fresh
  issue with no `[MELLON]` yields `await_start` and the sweep leaves it dormant
  (counted, not drafted); post `[MELLON]`, run the sweep, confirm one `[PLAN]` is
  drafted and the arc proceeds as the skeleton-stage flow already proves.

## Migration

Benign. In-flight tickets already bearing a `[PLAN]` are past the gate and
unaffected — the new branch is reached only when no `[PLAN]` exists. The only
behavior change is that *planless* tickets in a filter now sit dormant instead of
auto-drafting, which is the intent. No hook, no permission, no YouTrack setup added.

## Build size

```
Size ▰▰▱  medium — five files (decider + test + three skills + docs), but shallow
                   depth (one guarded return, one new no-op action) and easily
                   reversed.
```

Cleaves into minimum steps, each leaving the tree working:

1. **The pure gate.** `_is_mellon()` + the guarded return + `await_start`; update the
   one changed test, add the two new ones. Fully verifiable offline. (minimum)
2. **`/council` dormant handling.** `await_start` → no-op with its own line. (minimum)
3. **Sweep dispatch + tally.** `/aule` and `/glorfindel` skip `await_start` and
   report the count. (minimum)
4. **Docs.** README inventory line for the start gate; action-vocabulary table in the
   skeleton-stage plan/spec updated to include `await_start`. (minimum)
