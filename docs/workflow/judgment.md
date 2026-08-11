# Judgment Rubrics

> Read when a task wavers — before the third retry, before claiming done,
> before asking the user. Each rubric: signals, action, one positive and one
> negative example. Written so any model tier can execute it mechanically.

## 1 · Wrong direction — switch roads, do not retry harder

**Signals** (any two together = the road is wrong):

- The same *class* of error survives two genuinely different fixes.
- Each step reveals new unknowns instead of shrinking the remaining work.
- The fix keeps growing scope beyond what the task named.
- You are editing the test, the acceptance, or the verification to make it pass.
- You cannot explain in one sentence why the next attempt should behave differently.

**Action:** stop patching. Restate the problem in one paragraph from scratch,
list at least two alternative roads (different mechanism, not different
parameters), pick the most promising or ask the user if they differ materially
in cost.

- ✅ *Right:* a CSS fix for a layout bug fails twice in different ways; instead
  of a third selector tweak, you re-read the container and find the bug is a
  missing grid rule one level up — different road, one-line fix.
- ❌ *Wrong:* an HTTP call returns 401; you retry with a longer timeout, then
  with a retry loop, then with a different HTTP library. The road (auth is
  broken) never changed; three retries bought nothing.

## 2 · When to escalate the model

**Signals:**

- The task requires weighing trade-offs with no measurable winner (design,
  architecture, naming a public API).
- Two failed rounds at the current tier on the same subtask (see the ladder in
  `delegation.md` — carry the failure trail up).
- Instructions genuinely conflict and the repo's evidence cannot settle which
  rules (not merely "the task is long" — length is not depth).

**Action:** follow `delegation.md`'s escalation ladder. Escalation without the
failure trail is a fresh coin-flip, not an escalation.

**In the main session itself** (no subagent to re-dispatch), the ladder has no
lever to pull — say so instead of quietly trying another angle. When Rubric 1's
signals fire twice running in the direct back-and-forth with the user, name it
plainly and offer the choice: *"Two genuinely different fixes failed the same
way — this may be past what the current model tier can reliably do. Want to
switch to a stronger model, or should I try a third angle first?"* Do not
silently downgrade either — if the task turns out mechanical after a stronger
model solves it, name that too, so the user can drop back down next time.

- ✅ *Right:* a Sonnet session twice produces a decorator chain that breaks a
  test in a new way each time; it dispatches to `opus` with both diffs, both
  failures, and what was ruled out.
- ❌ *Wrong:* a Haiku search agent returns "no matches" once, and the session
  spawns Opus to re-run the same grep. The failure was a bad pattern, not a
  thin model — fix the pattern, stay cheap.
- ✅ *Right:* the main session (no subagent involved) tries two structurally
  different fixes for a flaky test, both fail the same way; it stops and tells
  the user plainly, naming the model-ceiling possibility, instead of trying a
  third patch silently.
- ❌ *Wrong:* the main session keeps re-patching the same function for five
  turns, each attempt slightly different, never naming that the road might be
  wrong or that a stronger model might be warranted.

## 3 · When to stop and ask the user

**Ask when** (any one):

- The next action is destructive or outward-facing beyond what the task named
  (deleting data, pushing, publishing, posting to a tracker not asked for).
- Two readings of the request diverge materially and the repo's evidence
  cannot settle which was meant.
- Honest completion requires widening scope past what was approved
  (CLAUDE.md's re-gauge rule is one instance of this).
- The work needs a secret, credential, or account action only the user holds.

**Do not ask when** the step is reversible and follows from the request —
proceed and report. Asking permission for work already approved is drift, not
care.

**How to ask.** Before asking, settle whatever the environment can answer — a
fact the repo, tools, or docs hold is looked up, never asked; only genuine
*decisions* (intent, preference, scope) go to the user. Attach your
recommended answer to every question, so the user reacts to a proposal, not a
blank prompt. Batch only independent questions; when one answer would reshape
another question, ask serially in dependency order.

- ✅ *Right:* asked to "clean up the test helpers", you find one helper is
  imported by another package — removing it widens the blast radius, so you
  name it and ask before touching.
- ❌ *Wrong:* asked to fix a typo in three files, you ask "shall I proceed with
  file 2?" after file 1. Nothing changed; the approval covered the task.
- ✅ *Right:* unsure which of two migration orders the user prefers, you ask
  one question with the safer order recommended, and hold the follow-up
  (whose options depend on the answer) for the next turn.
- ❌ *Wrong:* you batch "which database?" and "how should caching work?" in one
  call — the caching options depend on the database answer, so half the batch
  is guesswork.

## 4 · What "actually done" means

Done = **every acceptance line has same-turn evidence beside it**, per
CLAUDE.md's *Acceptance* and *Implementation Loop* (verification must be
fresh). Nothing silently skipped; anything deferred is named in the report.

- ✅ *Right:* "F2 done — `settings.json` parses (`python3 -c ...` this turn),
  all ten entries present (checked programmatically this turn)."
- ❌ *Wrong:* "Done — the tests passed earlier and the last change was small."
  A prior green run does not vouch for the current tree; a claim without a
  same-turn run is a guess wearing the clothes of a fact.

## 5 · Taste and ambiguity — the honest limit

Decomposition, verification, and multi-sample judging repair *execution*
quality. They do not repair **taste** (which name reads better, which tone
fits, which of two sound designs to prefer) or **under-specified intent**.
No checklist substitutes for the call.

**Action when a call is taste-shaped:** first check whether a standing rule
already decides it (the style docs, conventions of the codebase). If not:
escalate the model tier, or take a second independent opinion, or — when the
options are genuinely level — present both with a recommendation and let the
user pick. What is forbidden is presenting a coin-flip as a verdict.

- ✅ *Right:* two API shapes both satisfy every rule in `oo.md`; the session
  presents both, names the trade-off in two lines, recommends one, and lets
  the user choose.
- ❌ *Wrong:* the session silently picks one, reports "refactored to the
  cleaner design", and the user discovers the choice three commits later.

## 6 · Verifying a UI fix — drive the state the bug lives in

Fresh evidence for a UI fix must exercise the state the bug lives in, not the
page at rest. A screenshot at first load does not vouch for a bug that only
appears once interaction changes an element's size, visibility, or content — a
search dropdown open, a modal shown, a validation error rendered, a loading
spinner up.

**Action:** before claiming a UI fix done, name the state the bug lives in,
drive the page into it, and check the fix there. When the same layout shape
recurs elsewhere on the page (a second flex row, a repeated component), check
those instances in the same state too — one may hide the identical bug.

- ✅ *Right:* a flex row misaligns when the recipient field's search dropdown
  opens and grows taller than its siblings; you open the dropdown, screenshot,
  confirm the alignment holds in that state, then report done.
- ❌ *Wrong:* you fix the row against its empty first-load screenshot and report
  done — the user opens the live dropdown and finds the identical bug in the
  same row, untouched, because the taller state was never driven.

## 7 · A concrete external pointer outranks an unresolved internal thread

**Signal:** you are deep in a low-confidence investigation — an unknown scale
or unit, a missing access, an ambiguous metric with no clear resolution in
sight — and the user names a specific, concrete element instead ("the X
button looks wrong", "check the Y field").

**Action:** drop the ambiguous thread immediately and look at exactly what
they pointed to. Do not finish the current thread first out of momentum — a
specific human pointer at a real symptom outranks an unresolved technical
rabbit hole, every time.

- ✅ *Right:* mid-investigation on whether a login card's screen-coverage
  proportion is a bug — the export scale is unknown and the reference file's
  Figma node is inaccessible — the user says "the offline measurement button
  seems not right." You drop the proportion thread and look at that button;
  it turns out to be a confirmed color-token bug, found in under 5 tool calls.
- ❌ *Wrong:* you keep scanning pixel transitions to settle the proportion
  question "first," then get to the button the user actually asked about ten
  minutes later — after chasing a thread that may never resolve.

This mirrors Rubric 1's "switch roads" instinct, but the trigger differs:
Rubric 1 fires when your *own* fixes keep failing the same way; this fires
when the *user* supplies a higher-signal target while you are still
investigating, before you have even attempted a fix.
