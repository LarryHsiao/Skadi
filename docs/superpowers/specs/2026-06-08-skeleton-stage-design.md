# The Skeleton Stage — one living comment, modified in place

**Date:** 2026-06-08
**Status:** Design approved, awaiting spec review

## Purpose

Give the council → forge pipeline a missing middle rung: a **skeleton** the human
can eyeball and reshape *before* any real code is written. Adding a new action to an
existing project then walks three gated rungs on a single YouTrack issue —

1. **Plan** — what to build, which files, what decisions.
2. **Skeleton** — the *shape*: file tree, stubbed classes and method signatures, no
   bodies, plus a rendered PNG (class diagram or wireframe).
3. **Code** — the real diff, filled into the approved skeleton, opened as a draft PR.

Two `[FORTH]`s gate the arc: the first blesses the plan and triggers the skeleton;
the second blesses the skeleton and triggers the forge. No third gate — the draft PR
is reviewed and merged on the forge as `[GWAITH]` works today.

There is **no website and no server.** YouTrack is the surface; the live Claude Code
session, kept alive by `/loop`, is the engine.

## The governing principle

> **One living comment per stage, modified in place. No append, no versions.**

The plan is one comment the council keeps reshaping. The skeleton is one comment too.
The human comments; the agent rewrites. This is a deliberate reversal of `/council`'s
present append-only, versioned (`[COUNSEL v1]`, `v2`, …) grammar — see *Blast radius*.

## Scope

- **YouTrack as the only surface.** Jira is out of scope for this flow's modify-only
  variant in the first cut (Jira's comment model and the existing Jira hooks stay on
  the append grammar). The arc is proven on YouTrack first.
- **One issue = one action session.** The issue's description holds the original
  request, pristine; two living comments hold plan and skeleton; the human's comments
  carry instructions and approvals.
- **`/loop`-driven.** The human stamps `[FORTH]`s in YouTrack; a sweep wrapped in
  `/loop` advances every issue sitting on a stamped gate.

Out of scope: a bespoke web UI, the Agent SDK / headless `claude`, interactive (non-PNG)
previews, Jira support for the modify-only flow, cross-project sweeps in one tick.

## Surface and engine

- **Surface** — a YouTrack issue. No new infrastructure; reuses the existing
  `council-youtrack-*` hooks and credentials (one Vaultwarden `youtrack` item).
- **Engine** — the live Claude Code session running `/loop`. Each tick it queries
  candidate issues, derives each one's rung from its thread, does the work for any rung that
  owes the agent, writes back, and stops at the next gate. The browser (YouTrack's own web
  UI) is where the human reads artifacts and posts instructions/approvals.

## Issue anatomy

| Element | Holds | Who touches it |
|---|---|---|
| Description | The original request — **pristine** | nobody edits after creation |
| Plan comment *(one)* | The living plan | council **modifies** it |
| Skeleton comment *(one)* | File tree + stubbed signatures | celebrimbor **modifies** it |
| Attachment | The skeleton's PNG | re-rendered, replaced in place |
| Human comments | Instructions + `[FORTH]` approvals | human **appends** |

The plan and skeleton comments each open with a marker line so the sweep and the human
can find them: `[PLAN]` and `[SKELETON]` respectively. These are *markers on a single
living comment*, not append events — there is never a second `[PLAN]`.

## The gate — derived from the living comments

There is **no `Stage` field and no YouTrack setup.** The thread *is* the record: the rung
is derived from which living comments exist and where the latest `[FORTH]` sits relative to
each comment's watermark. This recovers council's creed — *the thread is the record* — for
the modify-only world.

| Condition on the thread | Rung — who owes |
|---|---|
| `[PLAN]` present, no `[FORTH]` past its watermark | **PlanReady** — human owes a verdict |
| `[FORTH]` past the plan's watermark, no `[SKELETON]` | **Skeleton** — agent owes work |
| `[SKELETON]` present, no `[FORTH]` past its watermark | **SkeletonReady** — human owes a verdict |
| `[FORTH]` past the skeleton's watermark, no `[GWAITH]` | **Coding** — agent owes work |
| `[GWAITH]` present | **Done** |

- The human approves by posting `[FORTH]`. On its next tick the agent derives the rung
  from the table and does the work the rung owes.
- Because the flow is strictly **sequential**, only one rung is ever pending, so a bare
  `[FORTH]` is unambiguous — it answers whatever rung awaits a verdict.
- Each living comment's first line carries a human-readable status for the eye
  (`[SKELETON] — awaiting [FORTH]`), but the derivation above — tokens + watermarks — is the
  source of truth.
- The sweep (`/glorfindel`, `/aule`) **fetches each candidate's thread** to derive the rung,
  exactly as those skills already fetch threads today — no new cost over current behavior.

## Two actors, two habits

- **The human appends, never edits** — instruction comments and the `[FORTH]` verdict.
- **The console modifies in place** — the plan comment, the skeleton comment, and the PNG
  attachment. It never appends a `v2`.

## Loop-safety — the watermark

An edited comment keeps its old thread position, so the loop cannot tell "already
handled" from "new instruction" by order alone — the signal `/council`'s append model
gave for free. Each living comment therefore carries the id (or timestamp) of the last
instruction it consumed, as a hidden trailer:

```
[PLAN]
<!-- consumed: 2026-06-08T14:22:07Z -->
... the living plan ...
```

Each tick, for a pending rung:

- A human comment **newer** than the watermark exists → re-draft the living comment,
  advance the watermark.
- Nothing newer and no `[FORTH]` → **no-op**; stay quiet. (Preserves the loop-safe
  invariant: repeated ticks between human replies do nothing.)

## The three rungs in detail

### Rung 1 — Plan (`/council`, converted to modify-only)

`/council` is rewritten so that, per issue, it maintains **one** `[PLAN]` comment:

- **First tick** (no `[PLAN]` comment): Erestor drafts the plan from the description; the
  skill **creates** the single `[PLAN]` comment and writes the watermark. The rung now
  derives as `PlanReady`.
- **Later ticks** with a human instruction newer than the watermark: Erestor redrafts;
  the skill **edits the same comment** in place and advances the watermark. Still `PlanReady`.
- The `[COUNSEL vN]` versioning, the five-turn limit's version counting, and the
  "fresh counsel after the bot's last word" ordering logic are **removed** for the
  YouTrack modify-only path and replaced by the single `[PLAN]` comment + watermark.

### Rung 2 — Skeleton (`/celebrimbor --skeleton`, new mode)

Once the rung derives as `Skeleton` (the 1st `[FORTH]` sits past the plan's watermark and
no `[SKELETON]` exists yet), a smith subagent runs in celebrimbor's existing isolated
worktree and:

- carves the **file tree + stubbed classes/method signatures** from the approved plan —
  no bodies, following the project's conventions read from the worktree;
- renders a **PNG** (see *Visual pipeline*) and **attaches** it to the issue, replacing
  the prior attachment;
- writes/edits the single `[SKELETON]` comment in place with the tree + stubs and the
  watermark, and stops. The rung now derives as `SkeletonReady`.

Human instructions reshape the same `[SKELETON]` comment, exactly as the plan rung.

### Rung 3 — Code (`/celebrimbor` forge, one new gate clause)

The forge gate changes from "`[COUNSEL vN]` + `[FORTH]` + no `[GWAITH]`" to the derived
`Coding` rung:

- a `[SKELETON]` comment exists, a `[FORTH]` sits past its watermark, **and** no `[GWAITH]`
  yet.

The smith then fills bodies into the approved skeleton, opens the draft PR, and posts
`[GWAITH]` — which itself marks the rung `Done`. All of celebrimbor's existing forge
machinery is unchanged below this clause.

## Visual pipeline — how a skeleton becomes a PNG

| Visual | Pipeline | Why |
|---|---|---|
| Class / sequence / state diagram | Mermaid → `mmdc` | terse text in, PNG out |
| Wireframe / layout | HTML → headless screenshot | reuses the henneth HTML; one artifact, two homes |
| Polished wireframe, no browser dep | frame0 (MCP) → `export_page_as_image` | native export, nothing to install |

The render tool is chosen per action: structural skeletons lean Mermaid; UI actions lean
the HTML/frame0 wireframe. The chosen renderer must exist on PATH (or as the MCP); absence
is surfaced and the rung stalls rather than silently skipping the visual.

## Blast radius — what changes

| Skill | Change |
|---|---|
| `/council` | Rewritten to modify-only on the YouTrack path: one `[PLAN]` comment + watermark. Versioned-append logic removed for this path. |
| `/celebrimbor` | New `--skeleton` mode (carve + render + `[SKELETON]` comment); forge gate keyed on the derived `Coding` rung instead of `[COUNSEL vN]`+`[FORTH]`. |
| `/aule`, `/glorfindel` | Derive the rung from each fetched thread (per the gate table); branch: `PlanReady`+`[FORTH]`→skeleton; `SkeletonReady`+`[FORTH]`→forge. |

**Migration note.** This is a breaking change to the council grammar on the YouTrack
path. In-flight tickets bearing `[COUNSEL vN]` history are not auto-migrated; the cut-over
applies to issues opened after the change. **No YouTrack setup is required** — the stage
lives in the comments, so there is no custom field to create.

## Open questions

None outstanding — surface, engine, artifact homes, gate mechanism, approval gesture, and
the two-`[FORTH]` count are all settled.

## Testing

- **Unit, automated** — rung derivation and the gate decision are pure functions over the
  thread: `rung(comments) -> {PlanReady | Skeleton | SkeletonReady | Coding | Done}` and
  `next_action(comments, watermarks) -> {redraft | advance | noop}`. Test against a named
  `expected` for each branch: `[PLAN]` only → PlanReady; `[FORTH]` past plan watermark, no
  `[SKELETON]` → Skeleton; `[SKELETON]` only → SkeletonReady; `[FORTH]` past skeleton
  watermark → Coding; `[GWAITH]` → Done; fresh instruction → redraft; nothing new → noop.
  No network.
- **Hook-shape** — the YouTrack edit-comment and set-field hooks verified against the
  `COUNCIL_DRY_RUN=1`-style dry path before any live write (mirroring the existing council
  hook discipline). Write-path smoke tests against the `MET-1` sandbox issue only.
- **End-to-end, manual** — open a YouTrack issue, run the loop; confirm one `[PLAN]`
  comment appears and *edits* (never duplicates) across two instructions; post `[FORTH]`,
  confirm the `[SKELETON]` comment + PNG appear and the rung advances; post the 2nd
  `[FORTH]`, confirm a draft PR and `[GWAITH]`. Named manual because YouTrack + a real PR
  cannot be asserted in a unit test.

## Build size

```
Size ▰▰▰  heavy — broad reach (four skills + new hooks + a YouTrack field),
                  deep thought (rewriting a load-bearing grammar), and hard to
                  reverse (other skills depend on council's append contract).
```

Cleaves into minimum steps, each leaving the tree working:

1. **The pure gate.** Write `rung(...)` / `next_action(...)` and their unit tests. No I/O. (minimum)
2. **YouTrack write hooks.** Edit-comment-in-place and attach-image hooks, dry-run
   verified, then smoke-tested on `MET-1`. (minimum)
3. **Convert `/council`** to the modify-only path: create/edit one `[PLAN]` comment +
   watermark. Verify on `MET-1`. (medium)
4. **`/celebrimbor --skeleton`.** Carve stubs + render PNG + `[SKELETON]` comment.
   Verify the skeleton comment and attachment on `MET-1`. (medium)
5. **Forge gate clause.** Key the existing forge on the derived `Coding` rung. Verify a
   draft PR from an approved skeleton. (minimum)
6. **Sweep + `/loop`.** Branch `/aule`/`/glorfindel` on the derived rung; confirm one
   sweep walks an issue across all gates. (medium)
7. **Docs.** README inventory lines for the new mode and the converted council path. (minimum)
