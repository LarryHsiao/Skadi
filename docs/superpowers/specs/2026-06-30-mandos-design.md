# `/mandos` — The Doom: weighing deed against decree

**Date:** 2026-06-30
**Status:** design approved, awaiting spec review

## Purpose

An independent gate that fetches a ticket's *goal* — its council plan, its own
text, and its parent's acceptance criteria — then weighs a finished branch
against it, and pronounces whether the work is faithful to what was asked.

Mandos (Námo), the Doomsman of the Valar, remembers every decree and weighs the
deed against it. Where `/mithrandir` weighs whether the code is *good*, `/mandos`
weighs whether it is the *right* code — faithful to the ticket's intent.

It complements, never duplicates:

- `/council` (Erestor) lays the plan on the ticket as `[COUNSEL]`/`[PLAN]`.
- `/celebrimbor` forges the PR/MR from the approved plan, marks `[GWAITH]`.
- `/mithrandir` weighs the code's soundness on its quality axes.
- **`/mandos` weighs the branch against the goal** — the seam none of the above fill.

## What makes it independent

The worth of the skill is that it does **not** trust the conversation that wrote
the code. Two guards make that real:

1. **Spec re-derived from the tracker, never from chat.** It pulls the ticket
   (and its parent) fresh on every run.
2. **The weighing runs in a read-only subagent** that receives *only* the
   harvested spec and the diff — blind to the build conversation. Fresh eyes by
   construction, mirroring the Compliance Review and Delegation Discipline.

## Spec harvest — the decree (all three sources)

For the resolved ticket, gather and fold together:

- **`[COUNSEL]`/`[PLAN]` comment** — council's settled plan, the detailed spec.
- **Ticket text** — summary, description, any AC list on the leaf itself.
- **Parent ticket**, if one exists — walk the link (Jira `parent`/epic link,
  YouTrack subtask-of) and harvest its **acceptance-criteria list**. AC most
  often lives on the parent epic; that list is the sharpest gate.

When *none* of the three bears explicit AC, derive implicit acceptance from the
description and **say plainly the gate is softer** — fail loud, not silently.

## Invocation — three forms, two write verbs

```
/mandos                      # branch-primary: current branch → derive ticket from branch name / commit subjects
/mandos TICKET-ID            # ticket-primary: fetch goal → resolve branch from [GWAITH] forge comment / naming convention
/mandos <pr-or-mr-url>       # URL form: weigh an open PR/MR against its ticket
/mandos post TICKET-ID       # write verb → thread verdict onto the ticket (confirm-once)
/mandos comment <url>        # write verb → post verdict on the PR/MR (confirm-once)

# flags (compose with any read/write form):
--deep                       # per-criterion fan-out (see Deep mode)
--plain / --lore             # tone override (mutually exclusive)
```

- **Branch-primary** (no positional): diff current branch vs base; derive the
  ticket id from the branch name prefix (`PSG-1234-foo` → `PSG-1234`) or commit
  subjects.
- **Ticket-primary** (`TICKET-ID` positional): fetch the goal, resolve the branch
  from the `[GWAITH]` forge comment (carries branch + URL) first, falling back to
  the branch-naming convention.
- **URL form**: weigh an open PR/MR against the ticket it names.
- **Write verbs** (`post`, `comment`): default is read-to-chat; these opt into a
  tracker or forge write behind a confirm-once gate.

**Routing reuse:** `tracker_routing.md` (MET→youtrack, PSG→jira) chooses the
tracker, exactly as `/council` and `/glorfindel` do. Base branch and
branch-naming reuse `/mithrandir` and `/celebrimbor` conventions.

## Verdict model — three buckets, each with severity

Walk every AC line / plan step and bucket it:

- **Covered** — evidence of it in the diff (name the `file:line`).
- **Missing** — asked, not built. Severity: **Blocker · Nice-to-have · Nit**.
- **Scope-crept** — built, never asked. Also severity-weighted.

**The gate:**

- Any **Blocker**-severity Missing or Scope-crept item → **Hold** (or **Astray**
  if several blockers stand).
- Only Nit-severity items outstanding → **Pass** (Faithful).
- Clean covering, nothing missing or crept → **Pass** (Faithful).

Tier labels follow `/mithrandir`'s grammar: **Faithful / Hold / Astray**
(sound · wavering · off), with the gauge glyphs `▰▱▱ / ▰▰▱ / ▰▰▰`.

## Deep mode (`--deep`) — one investigator per acceptance line

The default weighing reads all criteria against the whole diff in a single
subagent pass. `--deep` trades breadth for depth — the unit of fan-out is the
**acceptance criterion**, not the file (this is the axis that differs from
`/mithrandir`'s per-file `--deep`):

- **Partition** the harvested decree into its individual criteria (each AC line,
  each plan step).
- **Fan out** one read-only subagent per criterion, in parallel (cap concurrency,
  queue the rest). Each is handed **only its one criterion** plus the full diff,
  and charged to hunt the entire change for evidence that *this* line is met —
  returning Covered / Missing with a `file:line` and a severity.
- **Aggregate** every investigator's verdict into the three buckets and the gate.
  Scope-crept is judged in one final pass over the leftover diff no criterion
  claimed.

Composes with all three forms and either tone. A `--deep` tail-line under the
header names the breadth: *"Deep mode — N criteria weighed each on its own."*
Costs one agent per criterion; reach for it when the AC list is long and a quiet
miss would be costly.

## Render (chat default; same body posted on the write verbs)

```
> ▰▱▱ **Faithful** — every acceptance line is met; no drift.

# Mandos — <ticket-id>: <summary>
<branch> → <base> · weighed against [COUNSEL] + parent AC (EPIC-12)

## Covered
- `EPIC-12 AC1` — <evidence> `src/foo:42`

## Missing            ← omit if empty
### Blocker           ← omit subsection if empty
- `AC3` — <what was asked, not found>

## Scope-crept        ← omit if empty
### Nice-to-have      ← omit subsection if empty
- `src/bar` — <built beyond the decree>

## Doom ▰▰▱  Hold
<one paragraph naming the chief gap, in the active tone>
```

Tone defaults Tolkien (lore) in chat, plain on a forge/ticket post — the
`--plain`/`--lore` flags override either, as in `/mithrandir`.

## The `[DOOM]` token

`[DOOM]` (alias `[VERDICT]`) is Mandos's mark on the **ticket**.

- **Written** by the `post` verb only, as the threaded comment's first line:
  `[DOOM] <tier> — <one clause>` (e.g. `[DOOM] Hold — AC3 unmet, no logout path`).
- **Not** written in chat (no parser there) nor on the PR/MR comment (the forge
  is not read by the council loop; the tier rides the blockquote header there).
- **Must be recognized** by `/council`'s thread parser: in shared-identity mode
  (Jira), a comment's owner is decided by its first-line token. An unregistered
  `[DOOM]` comment would be misread as fresh human counsel, and the next
  `/council` ride would act on it. So `[DOOM]`/`[VERDICT]` is **added to
  council's bot-identity token list and its grammar table**.
- **Loop-neutral**, the class of `[PEDO]`/`[VINYA]`: it does not redraft (only
  `[ENVINYA]`), does not approve/reject/adjourn (Elrond's verdict tokens), does
  not forge or close (`[GWAITH]` / a human hand), and does not count toward the
  five-counsel turn limit.
- **Advisory.** A `[DOOM] Hold` does not auto-block any downstream merge skill;
  the gate is for a human to read and act on, per the standing rule that closing
  a ticket is a human verdict.

## Reuse vs. new

**Reuse:**

- Council fetch hooks (`council-youtrack-fetch.sh`, `council-jira-fetch.sh`) —
  ticket + thread.
- Lindir/Mithrandir PR read hooks — PR/MR diff and metadata.
- Mithrandir comment hooks — PR/MR verdict post.
- Council comment hooks — ticket `[DOOM]` post.
- The worktree helper (`skadi-worktree.sh`) — isolated read of the branch.
- `tracker_routing.md`, base-branch and branch-naming conventions.

**New, small:**

- A **parent-ticket fetch** — one field-follow on each tracker (Jira `parent` /
  epic link; YouTrack subtask-of) to pull the parent's AC.
- The **`/mandos` SKILL.md** — argument dispatch, spec harvest, branch/ticket
  resolution, weighing, render, write verbs.
- The **subagent prompt** (`mandos.md`) — the read-only weigher.
- A **small edit to `/council`** — admit `[DOOM]`/`[VERDICT]` to the bot-token
  list and the grammar table.

## Implementation steps (minimum-sized)

1. SKILL.md skeleton + argument dispatch (three forms, two verbs, flags) — no
   weighing yet.
2. Spec harvest, including the parent-ticket walk + no-AC fallback.
3. Branch/ticket resolution both directions.
4. The read-only weighing subagent (`mandos.md`) + render — default holistic
   pass, `--deep` per-criterion fan-out.
5. The two write verbs behind confirm-once gates.
6. The `/council` grammar edit admitting `[DOOM]`/`[VERDICT]`.

## Decisions taken (reversible)

- **No subagent fan-out by default** — one weighing agent. Independence comes from
  the blind spec, not agent count. `--deep` opts into per-criterion fan-out.
- **`[DOOM]` token** for the ticket post — registered loop-neutral in council.

## Size

```
Size ▰▰▱  medium — one new skill, one small parent-fetch hook addition, a small
                   council grammar edit; the rest woven from existing hooks.
                   Bounded, reversible (all new files but the council edit).
```
