# The `[MELLON]` start gate — lift the summons into the decider

**Date:** 2026-06-09
**Status:** Design approved (revised after codebase reconnaissance), awaiting spec review
**Builds on:** `docs/superpowers/specs/2026-06-08-skeleton-stage-design.md`

## Purpose

The skeleton-stage pipeline drafts a plan for **any** ticket a sweep's `--filter`
matches: the decider's final branch returns `draft_plan` unconditionally when no
`[PLAN]` exists (`hooks/skeleton-rung.py:82`). `/aule` therefore drafts plans on every
filtered ticket the first tick.

`/glorfindel` already guards against this with an **enrollment gate** at the skill
level (`skills/glorfindel/SKILL.md:113-117`): a ticket enrols only if it bears an
existing `[COUNSEL]`/`[PLAN]` or a `[MELLON]` summons from Elrond. `/aule` has no such
gate, and the decider — the single source of truth both sweeps route through — knows
nothing of `[MELLON]`.

This change **lifts that gate into the decider** so `/aule` inherits it and the rule
lives in one place. No new token is introduced: `[MELLON]` (alias `[FRIEND]`) already
exists and is documented (`README.md:116`, `skills/council/SKILL.md:262`).

## The token, as it already stands

| Token | Alias | Author | Meaning (existing) |
|---|---|---|---|
| `[MELLON]` | `[FRIEND]` | Elrond | Summons — *speak, friend, and enter*; enrols a ticket in `/glorfindel` sweeps. Ignored by single-ticket `/council` (the invocation itself is consent). |

This work **extends** that meaning to *"and gates plan-drafting across the
skeleton-stage sweeps (`/aule` and `/glorfindel`)"* — it does not redefine the token
or add an alias. The earlier draft of this spec proposed `[START]`; that is dropped in
favour of the established `[FRIEND]`.

## The governing principle

> **Every agent step in an unattended sweep is preceded by a human go-ahead.**

Today two of the three agent steps are gated by an `[FORTH]` (plan→skeleton,
skeleton→forge); the first — plan drafting — is gated only in `/glorfindel`, not in
`/aule` or the decider. `[MELLON]` closes that gap uniformly. It is an **entry** token,
not a third approval: it fires before anything is produced, when there is nothing to
approve. `[FORTH]` remains the **approval** token that blesses a produced artifact
onward. Two kinds of gesture, kept distinct.

The full arc, three human gestures unlocking three agent steps:

```
Elrond: [MELLON]   →  agent drafts  [PLAN]
Elrond: [FORTH]    →  agent draws   [SKELETON] + PNG
Elrond: [FORTH]    →  agent forges  the draft PR + [GWAITH]
```

## Where the gate lives — the decider derives, the caller decides

The decider (`skeleton-rung.py`) gains one derived state, `await_start`, computed
purely from the thread: no `[PLAN]` and no human `[MELLON]`/`[FRIEND]` → `await_start`.
This is the single source of truth.

**Callers decide what to do with it**, which is what preserves the established
"invocation = consent" convention:

- **Unattended sweeps** (`/aule`, `/glorfindel`) — `await_start` means *skip*. The
  human has not summoned the ticket; the sweep leaves it dormant.
- **Direct single-ticket `/council youtrack:<id>`** — the invocation **is** the
  summons. `/council` treats `await_start` as `draft_plan` and drafts. It is reached
  only by direct invocation or by a sweep that already cleared the gate, so it never
  needs to enforce the gate itself.

This honours both the one-source-of-truth instinct (the decider derives the rung) and
the documented convention (manual `/council` runs without `[MELLON]`).

## The gate — a fifth rung ahead of the rest

A pre-plan **Dormant** state joins the gate table ahead of all others. Every existing
row is unchanged.

| Condition on the thread | Rung — who owes |
|---|---|
| no `[PLAN]`, no `[MELLON]` | **Dormant** (`await_start`) — human owes the summons |
| no `[PLAN]`, `[MELLON]` present | **PlanReady** (`draft_plan`) — agent drafts the plan |
| `[PLAN]`, no `[FORTH]` past its watermark | PlanReady — human owes a verdict |
| `[FORTH]` past plan, no `[SKELETON]` | Skeleton — agent owes work |
| `[SKELETON]`, no `[FORTH]` past its watermark | SkeletonReady — human owes a verdict |
| `[FORTH]` past skeleton, no `[GWAITH]` | Coding — agent owes work |
| `[GWAITH]` present | Done |

`[MELLON]` is detected exactly as `/glorfindel` already detects it and as `[FORTH]` is:
any **human** comment (login ≠ `BOT_LOGIN`) whose text bears `[MELLON]` or `[FRIEND]`,
case-insensitive, anywhere in the body. Presence only — no watermark relation —
because it is an entry gate that fires before any artifact exists. Once a `[PLAN]` is
on the thread the decider never returns `await_start`, so `[MELLON]` ceases to matter
and the flow proceeds by watermark and `[FORTH]` as before.

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

plus a `_is_mellon()` twin of `_is_forth()` and a `SUMMONS = ("[MELLON]", "[FRIEND]")`
module constant mirroring `VERDICT`. The new action `await_start` joins the action
vocabulary. Everything below the `if plan:` branch is unchanged — this is the only
edit to `decide()`.

### Deliberate strictness

A bare `[FORTH]` on a planless ticket does **not** open the gate; only
`[MELLON]`/`[FRIEND]` does. There is nothing to approve before a plan exists, so an
`[FORTH]` there is meaningless. Keeping the openers distinct avoids a confusing back
door (a stray approval silently starting work no one asked to begin).

## The skills

| Skill | Change |
|---|---|
| `/council` (YouTrack path) | Map `await_start` → draft the plan (invocation = consent). One clause: where the action branch handles `draft_plan`, `await_start` joins it. No gate enforcement — reaching `/council` already means consent. |
| `/aule` | Rung-dispatch table gains `await_start → skip`; the closing report carries a tally: *"N ticket(s) await `[MELLON]` — dormant until summoned."* Dropped from the work manifest, surfaced as a count. |
| `/glorfindel` (YouTrack path) | The skill-level enrolment gate now leans on the decider: `await_start` is the mechanism behind the existing `untouched` action. The Jira path keeps its own skill-level gate (no decider there). |

`/glorfindel` already reports un-summoned tickets as `untouched`; that vocabulary is
kept. `/aule` has no equivalent, so its dormant tally is new — a deliberate, narrow
divergence from the skeleton-stage "drop no-ops silently" rule, guarding against a
backlog of un-summoned tickets looking identical to an empty project.

## Testing

- **Unit, automated** — `tests/test_skeleton_rung.py`. The existing
  `test_empty_thread_drafts_plan` **changes meaning**: an empty thread now yields
  `await_start`, not `draft_plan`; it is renamed (`test_empty_thread_awaits_start`)
  and its `expected` updated. Two new tests land:
  - `test_mellon_drafts_plan` — a human `[MELLON]` comment, no `[PLAN]` → `draft_plan`.
  - `test_friend_alias_drafts_plan` — the `[FRIEND]` alias → `draft_plan`.

  The seven downstream tests each carry a `[PLAN]`, so they never reach the gated
  branch and stand as-is. No network.
- **End-to-end, manual** — on a YouTrack sandbox issue (`MET-1`), confirm: a fresh
  issue with no `[MELLON]` yields `await_start` and `/aule` leaves it dormant
  (counted, not drafted); post `[MELLON]`, run the sweep, confirm one `[PLAN]` is
  drafted and the arc proceeds as the skeleton-stage flow already proves. Confirm a
  direct `/council youtrack:MET-1` on a no-`[MELLON]` issue still drafts.

## Migration

Benign. In-flight tickets already bearing a `[PLAN]` are past the gate and unaffected —
the new branch is reached only when no `[PLAN]` exists. `/glorfindel`'s behaviour is
unchanged in effect (it already gated on `[MELLON]`); the gate simply moves to the
decider. The one new behaviour is that `/aule` now leaves un-summoned planless tickets
dormant instead of auto-drafting — the intent. No hook, no permission, no YouTrack
setup added.

## Build size

```
Size ▰▰▱  medium — five files (decider + test + three skills + docs), but shallow
                   depth (one guarded return, one new no-op action, caller wiring)
                   and easily reversed.
```

Cleaves into minimum steps, each leaving the tree working:

1. **The pure gate.** `_is_mellon()` + `SUMMONS` + the guarded return + `await_start`;
   update the one changed test, add the two new ones. Fully verifiable offline. (minimum)
2. **`/council` consent clause.** `await_start` → draft on the YouTrack path. (minimum)
3. **Sweep dispatch + tally.** `/aule` skips `await_start` and reports the count;
   `/glorfindel` YouTrack path leans on the decider for its `untouched` gate. (minimum)
4. **Docs.** Broaden the `[MELLON]` token description (README + council token table)
   to name the sweep plan-gate; add `await_start` to the skeleton-stage action
   vocabulary. (minimum)
