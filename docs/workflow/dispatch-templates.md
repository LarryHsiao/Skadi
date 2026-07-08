# Dispatch Templates

> Fill-in prompts for delegating the five common task shapes. Copy the block,
> fill every `<...>` slot, delete lines that truly do not apply. The rules
> behind the slots: `delegation.md` (triad, report contract, roster).
> Every template ends with acceptance and report format — a dispatch missing
> either is not ready to send.

## Search / locate

Suggested model: `haiku` (one failed round → `sonnet`).

```
Find <what> in <repo/path scope>.
Why: <one line — what the answer unlocks>.
Look via: <naming conventions, likely directories, related terms to try>.
Acceptance: every location found, or an explicit "none found after checking
<the places you name>" — absence must be stated, not implied.
Report: file:line per hit, one-line context each, nothing else. Max <N> lines.
Read-only — change nothing.
```

## Implement

Suggested model: `sonnet`. One writer per seam — no parallel implementer on
the same files.

```
Implement <change> in <files/module>.
Why: <one line>.
Constraints: <style rules that apply, patterns to follow — name the file to
imitate>; touch only <files>; no features beyond this.
New code lands with a test (see docs/style/general.md — write the test first,
watch it fail for the named reason, then make it green).
Acceptance: <the red-then-green test(s)>; <observable behavior>; existing
tests still pass (run <command>).
Report: what changed as file:line list, the test command you ran and its
actual output tail. If blocked: say what is missing — do not improvise scope.
```

## Refactor

Suggested model: `sonnet`; `opus` when the shape itself is being redesigned.

```
Refactor <what> from <current shape> to <target shape>.
Why: <one line>.
Behavior must not change: <the tests/command that pin current behavior — if
none exist, write pinning tests FIRST and show them green before reshaping>.
Constraints: touch only <files>; keep each commit-sized step coherent.
Acceptance: pinning tests green before AND after; no public API change beyond
<the named ones>; diff contains no unrelated edits.
Report: before/after shape in two lines each, file:line list, test output tail.
```

## Research

Suggested model: `sonnet`; `haiku` only for single-source lookups.

```
Question: <the question, self-contained — the agent has not seen this chat>.
Why: <what decision the answer feeds>.
Sources: <repo paths / web / docs — name where to look and what counts as
authoritative>.
Acceptance: the question answered with evidence per claim (file:line or URL);
claims that could not be verified are marked unverified, not dropped.
Report: answer first (≤5 lines), then evidence list. Long findings go to
<path> on disk; reply carries the path plus a 3-line summary.
Read-only — change nothing.
```

## Review

Suggested model: `sonnet` for rule-based review; `opus` when the spec itself
may be wrong. Reviewer must be fresh-context — never the author.

```
Review <the diff / files> against <the spec: what was supposed to be built>
and <the rules: docs/style/*.md, conventions of the codebase>.
Order: spec compliance first (missing pieces AND unasked-for additions),
then quality. Over-built is as much a failure as under-built.
Read-only — report, do not fix.
Acceptance: every finding carries file:line, what is wrong, and severity
(blocker / minor / nit); a clean pass says PASS explicitly.
Report: verdict line first, then numbered findings, most severe first.
Max <N> findings — if more exist, say so.
```
