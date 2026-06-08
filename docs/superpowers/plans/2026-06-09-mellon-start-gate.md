# [MELLON] Start Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the existing `[MELLON]` enrolment gate into the skeleton-stage decider so `/aule` inherits it, gating plan-drafting on an Elrond summons across both sweeps while leaving direct `/council` to draft on its own authority.

**Architecture:** `hooks/skeleton-rung.py` gains one derived action, `await_start` (no `[PLAN]` and no human `[MELLON]`/`[FRIEND]` → dormant). The decider is the single source of truth; callers decide what to do with `await_start` — sweeps skip it, direct `/council` treats its own invocation as the summons and drafts. No new token (`[MELLON]`/`[FRIEND]` already exists), no new hook, no new permission.

**Tech Stack:** Python 3 stdlib (`unittest`) for the decider; Markdown skills; YouTrack REST via existing hooks.

**Spec:** `docs/superpowers/specs/2026-06-09-mellon-start-gate-design.md`

---

## File structure

| File | Responsibility | Created / Modified |
|---|---|---|
| `hooks/skeleton-rung.py` | Add `_is_mellon()`, `SUMMONS`, the `await_start` branch | Modify |
| `tests/test_skeleton_rung.py` | Flip the empty-thread test; add `[MELLON]` + `[FRIEND]` tests | Modify |
| `skills/council/SKILL.md` | YouTrack path: `await_start` → draft (invocation = consent) | Modify |
| `skills/aule/SKILL.md` | Dispatch table `await_start → skip`; dormant tally in the report | Modify |
| `skills/glorfindel/SKILL.md` | YouTrack path: name the decider's `await_start` as the `untouched` mechanism | Modify |
| `README.md` | Broaden the `[MELLON]` token description to name the sweep plan-gate | Modify |

**Bot identity:** the decider keys bot-vs-human on `BOT_LOGIN = "claude"` (`hooks/skeleton-rung.py:15`). `[MELLON]` is counted only from non-bot comments.

---

## Task 1: The pure gate (decider + tests)

**Files:**
- Modify: `hooks/skeleton-rung.py`
- Modify: `tests/test_skeleton_rung.py`

- [ ] **Step 1: Change the failing/affected tests**

In `tests/test_skeleton_rung.py`, **replace** the existing `test_empty_thread_drafts_plan` method (lines 18-20) with the renamed test plus two new ones:

```python
    def test_empty_thread_awaits_start(self):
        expected = "await_start"
        self.assertEqual(decide({"comments": []})["action"], expected)

    def test_mellon_drafts_plan(self):
        expected = "draft_plan"
        data = {"comments": [human("[MELLON]", 100)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_friend_alias_drafts_plan(self):
        expected = "draft_plan"
        data = {"comments": [human("please look at this [FRIEND]", 100)]}
        self.assertEqual(decide(data)["action"], expected)
```

(The `human(text, created)` helper already exists at line 14. The seven other tests each carry a `[PLAN]` comment, so they never reach the gated branch — leave them untouched.)

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `python -m unittest tests.test_skeleton_rung -v`
Expected: FAIL — `test_empty_thread_awaits_start` and `test_mellon_drafts_plan`/`test_friend_alias_drafts_plan` fail because `decide()` still returns `draft_plan` for an empty/no-`[PLAN]` thread regardless of `[MELLON]`. The other seven pass.

- [ ] **Step 3: Add the summons detector and constant**

In `hooks/skeleton-rung.py`, after the `VERDICT` constant (line 17), add:

```python
SUMMONS = ("[MELLON]", "[FRIEND]")
```

After the `_is_forth()` function (ends line 38), add:

```python
def _is_mellon(text):
    up = (text or "").upper()
    return any(s in up for s in SUMMONS)
```

- [ ] **Step 4: Guard the final return**

In `decide()`, replace the final line (line 82):

```python
    return out("draft_plan")
```

with:

```python
    has_mellon = any(_is_mellon(c.get("text", "")) for c in humans)
    return out("draft_plan") if has_mellon else out("await_start")
```

(`humans` is already bound at line 55. This is the only change to the function body.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m unittest tests.test_skeleton_rung -v`
Expected: PASS — all 10 tests green (7 original + the renamed empty-thread test + 2 new summons tests).

- [ ] **Step 6: Verify the CLI shape end-to-end**

Run (no `[MELLON]`, dormant):
```bash
echo '{"comments":[]}' | python hooks/skeleton-rung.py
```
Expected: `action=await_start plan_id=- skeleton_id=-`

Run (with `[MELLON]`, drafts):
```bash
echo '{"comments":[{"login":"elrond","text":"[MELLON]","created":100,"id":"h100"}]}' | python hooks/skeleton-rung.py
```
Expected: `action=draft_plan plan_id=- skeleton_id=-`

- [ ] **Step 7: Commit**

```bash
rtk git add hooks/skeleton-rung.py tests/test_skeleton_rung.py
rtk git commit -m "feat(skeleton-rung): gate draft_plan on the [MELLON] summons"
```

---

## Task 2: /council consent clause (YouTrack path)

`/council` is reached only by direct invocation or by a sweep that already cleared the gate, so it never enforces the gate — it drafts. Today its YouTrack branch (`skills/council/SKILL.md:108-127`) sends `await_start` (via the catch-all "anything else") to a no-op. Pull `await_start` into the draft clause.

**Files:**
- Modify: `skills/council/SKILL.md:108-127`

- [ ] **Step 1: Rewrite the draft-plan bullet to include `await_start`**

Replace the `draft_plan` bullet (lines 109-121, beginning `- \`draft_plan\` — summon Erestor`) — keep its body, change only the leading clause:

```markdown
   - `draft_plan` **or** `await_start` — summon Erestor (worktree per the
     Working-directory contract); he drafts the plan body. `await_start` means the
     thread bears no `[MELLON]` summons, but reaching `/council` directly **is** the
     summons (the invocation is consent), so it drafts exactly as `draft_plan` does.
     Erestor still returns his `[COUNSEL vN]` envelope; strip that envelope and wrap
     his body as the `[PLAN]` comment. **Create** the comment with the marker,
     watermark, and body:
```

(Leave the fenced `[PLAN]` example block and the "Post it via …" line that follow unchanged.)

- [ ] **Step 2: Tighten the no-op bullet so it no longer swallows `await_start`**

Replace the no-op bullet (lines 126-127):

```markdown
   - `await_plan` / `draft_skeleton` / anything else — **no-op**. Council's job is
     the plan rung only; later rungs belong to celebrimbor. Report "awaiting" and stop.
```

with:

```markdown
   - `await_plan` / `draft_skeleton` / `redraft_skeleton` / `forge` / `done` —
     **no-op**. Council's job is the plan rung only; later rungs belong to celebrimbor.
     Report "awaiting" and stop. (`await_start` is handled by the draft clause above —
     a direct invocation is consent.)
```

- [ ] **Step 3: Verify the edit reads correctly**

Run: `python -c "t=open('skills/council/SKILL.md').read(); assert t.count('await_start')>=2, 'await_start not wired into both clauses'; assert 'anything else' not in t.split('Watermark rule')[0], 'catch-all still swallows await_start'; print('ok')"`
Expected: `ok` — `await_start` names appear in both the draft clause and the no-op clause, and the catch-all "anything else" that would have swallowed it is gone.

- [ ] **Step 4: Commit**

```bash
rtk git add skills/council/SKILL.md
rtk git commit -m "feat(council): draft on await_start (direct invocation is consent)"
```

---

## Task 3: Sweep dispatch + dormant tally

**Files:**
- Modify: `skills/aule/SKILL.md` (dispatch table ~lines 83-92; report ~lines 150-164)
- Modify: `skills/glorfindel/SKILL.md` (YouTrack rule ~lines 184-188)

- [ ] **Step 1: Add `await_start` to Aulë's skip row**

In `skills/aule/SKILL.md`, the YouTrack rung-dispatch table currently ends with a skip row for `await_plan, await_skeleton, done`. Replace that row:

```markdown
| `await_plan`, `await_skeleton`, `done` | skip (no-op) |
```

with:

```markdown
| `await_start` | skip — dormant, no `[MELLON]` summons yet (counted in the report) |
| `await_plan`, `await_skeleton`, `done` | skip (no-op) |
```

- [ ] **Step 2: Add the dormant tally to Aulë's report**

In `skills/aule/SKILL.md`, the sweep-complete report's closing line currently reads (around line 163):

```markdown
<Q-K> qualifier(s) remain for the next sweep.
```

Add, immediately beneath it:

```markdown
<D> ticket(s) await [MELLON] — dormant until summoned.
```

and add to the prose just below the report block: *"The dormant tally `<D>` counts tickets the decider returned `await_start` for — planless and un-summoned. They are dropped from the work manifest, surfaced only as this count so a backlog of un-summoned tickets does not read as an empty project."*

- [ ] **Step 3: Name the decider as Glorfindel's YouTrack enrolment mechanism**

In `skills/glorfindel/SKILL.md`, the "YouTrack path is modify-only" rule (lines 184-188) currently explains loop-safety via `await_plan`. Append one sentence to that paragraph:

```markdown
  On the YouTrack path the enrolment gate (step 3) is the decider's own work: a
  planless ticket with no `[MELLON]`/`[FRIEND]` summons yields `await_start`, which
  Glorfindel records as `untouched` — the same outcome the skill-level gate gave,
  now derived in one place. The Jira path keeps its skill-level engagement gate.
```

- [ ] **Step 4: Verify the edits read correctly**

Read `skills/aule/SKILL.md` around the dispatch table and report, and `skills/glorfindel/SKILL.md:184-192`. Confirm by eye:
- Aulë's table has an `await_start → skip` row and the report carries the `await [MELLON]` tally line.
- Glorfindel's YouTrack rule names `await_start` as the mechanism behind `untouched`.
Expected: both sweeps now describe the dormant outcome; no contradiction with the decider's vocabulary.

- [ ] **Step 5: Commit**

```bash
rtk git add skills/aule/SKILL.md skills/glorfindel/SKILL.md
rtk git commit -m "feat(sweep): aule skips await_start with a dormant tally; glorfindel leans on the decider"
```

---

## Task 4: Docs + propagation

**Files:**
- Modify: `README.md` (token table line ~116; sweep description line ~105)
- Modify: `skills/council/SKILL.md` (token table line ~262)
- Modify: `docs/superpowers/plans/2026-06-08-skeleton-stage.md` (action vocabulary table ~lines 34-46)

- [ ] **Step 1: Broaden the `[MELLON]` token row in the README**

In `README.md`, replace the token-table row (line ~116):

```markdown
| `[MELLON]` | `[FRIEND]` | Elrond | Summons — *speak, friend, and enter*; enrolls a ticket in `/glorfindel` sweeps |
```

with:

```markdown
| `[MELLON]` | `[FRIEND]` | Elrond | Summons — *speak, friend, and enter*; enrols a planless ticket in the skeleton-stage sweeps (`/glorfindel` and `/aule`). Un-summoned planless tickets stay dormant; direct single-ticket `/council` drafts without it |
```

- [ ] **Step 2: Broaden the README sweep description**

In `README.md`, the `/glorfindel` sweep bullet (line ~105) ends *"…so a fresh project is not flooded with v1 drafts on the first ride."* Append:

```markdown
 The same `[MELLON]` summons gates plan-drafting in `/aule`; the gate is derived once, in `hooks/skeleton-rung.py` (`await_start`).
```

- [ ] **Step 3: Broaden the council token row**

In `skills/council/SKILL.md`, replace the token-table row (line ~262):

```markdown
| `[MELLON]` | `[FRIEND]` | Elrond | Summons. *Speak, friend, and enter* — enrolls a ticket in `/glorfindel` sweeps. Ignored by single-ticket `/council` (the invocation itself is consent). |
```

with:

```markdown
| `[MELLON]` | `[FRIEND]` | Elrond | Summons. *Speak, friend, and enter* — enrols a planless ticket in the skeleton-stage sweeps (`/glorfindel`, `/aule`); the decider yields `await_start` without it. Ignored by single-ticket `/council` (the invocation itself is consent). |
```

- [ ] **Step 4: Add `await_start` to the skeleton-stage action vocabulary**

In `docs/superpowers/plans/2026-06-08-skeleton-stage.md`, the action-vocabulary table (the rows beginning `draft_plan`, around line 37) lists the decider's actions. Add a row at the top of that table body:

```markdown
| `await_start` | No `[PLAN]` and no `[MELLON]`/`[FRIEND]` summons | noop (sweep skips; direct `/council` drafts) |
```

- [ ] **Step 5: Run the full unit suite once more**

Run: `python -m unittest discover tests -v`
Expected: PASS — all 10 decider tests green.

- [ ] **Step 6: Commit**

```bash
rtk git add README.md skills/council/SKILL.md docs/superpowers/plans/2026-06-08-skeleton-stage.md
rtk git commit -m "docs(mellon-gate): broaden the [MELLON] token to the sweep plan-gate"
```

- [ ] **Step 7: Propagate the live config**

Invoke the `/install` skill (per the repo's propagation rule) so the changed `skeleton-rung.py` and skills land in every configured Claude root. Do **not** run `./install.sh` directly.

---

## Notes for the executor

- **Spec is YouTrack-only.** Every behavioural change is gated to the YouTrack path; the Jira `[COUNSEL vN]` append grammar and Glorfindel's Jira skill-level gate are untouched.
- **No new hook, no new permission.** `skeleton-rung.py` already carries a `permissions.allow` entry; this change edits it in place.
- **`MET-1` is the only write-path sandbox** for any manual end-to-end check. The decider tests are pure and need no creds; manual YouTrack verification (post `[MELLON]`, sweep, confirm one `[PLAN]`) requires the `youtrack` Vaultwarden item — surface a credentials error and pause rather than fake a pass.
- **The strictness to preserve:** a bare `[FORTH]` on a planless ticket must **not** open the gate — only `[MELLON]`/`[FRIEND]` does. The decider already enforces this because `_is_forth` is consulted only inside the `if plan:`/`if skeleton:` branches, never at the final gated return.
