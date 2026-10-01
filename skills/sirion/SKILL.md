---
name: sirion
description: Use when the user runs /sirion [fix|feat] [<slug>] [--mend all|blockers|none] [--full]. Carries local work from a dirty tree all the way into the default branch in one call — cuts a fix/ or feat/ branch (or reuses the feature branch already checked out), commits via /commit, weighs the branch with /mithrandir branch, mends its To pass findings per --mend (all by default; blockers only; or none), pushes the feature branch, then hands off to /celebrant to merge with --no-ff, push, and delete the branch local and remote. Celebrant's one confirm still stands before the destructive steps.
purpose: Branches, commits, reviews, mends, pushes, and merges local work into the default branch in one call.
args: "[fix|feat] [<slug>] [--mend all|blockers|none] [--full]"
user_invocable: true
---

# Sirion — The River to the Sea

Sirion rose in the north of Beleriand and ran the whole length of the land to the sea. So this skill: work that stands uncommitted on the tree is carried the whole course — branched, committed, weighed, mended, pushed — until `/celebrant`, its last reach, pours it into the default branch.

## Ethos

- **Compose, do not duplicate.** Each reach is an existing skill — `/commit`, `/mithrandir branch`, `/celebrant`. Sirion orders them and carries state between them; it re-implements none.
- **The mend is the caller's choice.** `--mend` decides how much of Mithrandir's `To pass` list is fixed before the merge. Whatever is left unmended is named in the report, never dropped.
- **The confluence keeps its own gate.** `/celebrant` confirms once before merge, push, and delete. Sirion adds no second gate and removes none.

## Argument parsing

`/sirion [fix|feat] [<slug>] [--mend all|blockers|none] [--full]`

| Argument | Required | Meaning |
|---|---|---|
| `fix` / `feat` | no | Branch prefix. Inferred from the diff when omitted: a defect corrected → `fix`, new capability → `feat`. |
| `<slug>` | no | Branch name after the prefix, kebab-case. Drafted from the diff when omitted. |
| `--mend` | no | `all` (default) — fix every `To pass` row; `blockers` — fix only `### Blocker` rows; `none` — fix nothing. Any other value: stop and name the three legal ones. |
| `--full` | no | Passed through to `/celebrant`, which then runs the full `/argonath` gate. |

## Workflow

### 1. Orient

```bash
git rev-parse --abbrev-ref HEAD
git status --porcelain
```

Resolve the default branch (`<target>`) by `/celebrant`'s *Target resolution* order — `base_branch.md` entry, then `origin/HEAD`, then `master`, then `main`.

| Current branch | Tree | Action |
|---|---|---|
| `<target>` | dirty | Cut a branch — step 2. |
| `<target>` | clean | Stop: *Nothing to carry — the tree is clean on `<target>`.* |
| any other | either | Reuse it; skip step 2. Any `fix\|feat` or `<slug>` argument is ignored — say so in one line. |

On a reused branch, after step 3 count `git rev-list --count <target>..HEAD`; at `0` stop: *Nothing to carry — no commits ahead of `<target>`.*

### 2. Cut the branch

```bash
git switch -c <prefix>/<slug>
```

The uncommitted changes ride onto the new branch. If the name already exists, stop and report it — never overwrite.

### 3. Commit

Skip when the tree is clean. Otherwise invoke `/commit` via the Skill tool (no `--push`).

### 4. Review

Invoke `/mithrandir branch` via the Skill tool. Hold its verdict (Merge / Hold / Refuse, with tier) and its `## To pass` rows by severity group. No `## To pass` section means no rows — skip step 5.

`/mithrandir branch` resolves its own base (`master`, then `main`, then `origin/HEAD`) and ignores `base_branch.md`. When that base differs from `<target>`, say so in one line, and carry both into step 7.

### 5. Mend

| `--mend` | Rows fixed |
|---|---|
| `all` | Blocker, Nice to have, Nit |
| `blockers` | Blocker only |
| `none` | none — skip to step 6 |

Fix each selected row in the working tree, reading the cited `file:line` first. When a row cannot be fixed without a decision only the user can make, leave it and name it in the report. Run the project's static analysis once after the fixes (whatever `/argonath`'s detection names, or the repo's own lint command); on a failure, mend it and re-run once; if it still fails, stop per *Rules*. Then invoke `/commit` once for all the mends. No re-review — `/celebrant`'s `/argonath` gate weighs the result.

### 6. Push

```bash
git push -u origin HEAD
```

### 7. Hand off

Invoke `/celebrant <target>` via the Skill tool, adding `--full` when it was given. Before it runs, print the carry so the user sees it beside Celebrant's confirm:

```
Branch : <branch>  (<cut | reused>)
Commits: <n> ahead of <target>
Review : <Merge | Hold | Refuse> (<tier>)  — against <mithrandir-base> when it differs from <target>
Mend   : <all|blockers|none> — fixed <n>, left open <n> (<Blockers open: n>)
```

`/celebrant`'s default `--quick` gate does not re-run `/mithrandir`, so this carry is where a Blocker left open is seen. Sirion still hands off; Celebrant's confirm is the gate.

If the user declines at Celebrant's confirm, stop there: the branch stays pushed and intact.

## Report

```
Branch : <branch>  → <target>
Review : <Merge | Hold | Refuse> (<tier>)
Mend   : fixed <n> · left open <n> (<rows, one line each>)
Merged : <✓ | declined | stopped — reason>
```

## Rules

- Never force-push and never force-delete; `/celebrant` owns the merge and delete and keeps its `-d` rule.
- A conflict, a failed push, or a failed analysis run stops the flow where it stands — report it, and do not hand off to `/celebrant`.
- Unfixed rows under `--mend blockers` or `none` are reported, never silently dropped.
