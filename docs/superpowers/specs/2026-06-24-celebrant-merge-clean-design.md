# /celebrant — merge a feature branch up and clean it away

**Date:** 2026-06-24
**Status:** design, awaiting review

## Purpose

When work on a feature branch is done, the user wants one ordered word to:
land it on the repo's default branch with a real merge commit, push, and clear
the now-merged branch away — local and remote. Today this is a hand-run sequence
of `git checkout` / `pull` / `merge` / `push` / `branch -d` / `push --delete`,
easy to fumble and easy to forget the cleanup.

## Why a skill, not a rule

A `CLAUDE.md` rule governs always-on background behaviour (tone, task-sizing,
the approval gate). This is the opposite: a named, on-demand workflow with
ordered steps and destructive side effects (a merge into the default branch, a
push, a branch deleted). That is exactly what the existing skill family is —
`/commit`, `/branch`, `/aule`. A skill is summoned by name (the invocation is
the word of approval), carries its own confirm gate, and costs nothing until
called — where a rule would lean on phrasing-recognition and tax every
conversation.

## Invocation

```
/celebrant [target] [--full]
```

- `target` — the branch to merge into. Optional; resolved per the order below.
- `--full` — run the full `/argonath` gate (with the `/nazgul` + `/mithrandir`
  advisory rows). Default is `/argonath --quick` (artefact commands + secret
  scan only).

## Target resolution

The default branch is **not** assumed to be `master`. Resolve in order, first hit wins:

1. explicit `target` argument
2. `base_branch.md` memory entry for this repo root (the same map `/celebrimbor` reads)
3. `git symbolic-ref refs/remotes/origin/HEAD`, stripped of the `origin/` prefix
4. fall back to `master` if it exists, else `main`

## Steps

1. **Orient & refuse early.**
   - Verify a git repo; capture the current (feature) branch.
   - Resolve `target` per the order above.
   - Refuse if the current branch *is* the target — there is nothing to merge up.
   - Refuse if the working tree is dirty — a half-committed state must not ride
     into the default branch. Report the dirty paths and stop.

2. **Pre-merge gate.**
   - Invoke `/argonath --quick` by default, or `/argonath` (full) when `--full`
     is given. Argonath weighs the about-to-merge work and returns a single
     **Pass / Hold** verdict.
   - A **Hold** does not hard-stop. It is carried into the confirm step as a
     warning, so the user keeps the final say.

3. **Confirm once.**
   - Present the plan: `<feature> → <target>`, that `target` will be pulled,
     merged `--no-ff`, pushed, and the feature branch deleted (local, and
     remote if it exists) — alongside the Argonath verdict.
   - Ask once (AskUserQuestion). Proceed only on the user's word.

4. **Run the flow (on approval):**
   ```
   git checkout <target>
   git pull origin <target>               # explicit, so a no-upstream target still updates
   git merge --no-ff --no-edit <feature>  # a real merge commit, git's default message
   git push
   git branch -d <feature>                # safe-delete: refuses if unmerged
   git push origin --delete <feature>     # only if a remote branch exists
   ```
   - `-d` (lowercase) is deliberate over `-D`: since the branch was just merged,
     `-d` succeeds; if anything is off, it stops loud rather than force-deleting.
   - The remote delete runs only when `git ls-remote --exit-code origin <feature>`
     finds the branch.

5. **Report.** What merged, the merge-commit subject, what was deleted (local /
   remote), and the gate's verdict.

## Failure handling

- Dirty tree or already-on-target → refuse before any state changes, report plainly.
- `git pull` conflict or `git merge` conflict → stop, leave the tree as git left
  it, report the conflicting paths; do not push, do not delete.
- `/argonath` Hold → warn at the confirm step; user decides.
- Remote branch absent → skip the remote delete silently (it is not an error).

## Out of scope

- Committing uncommitted work first (a separate flow; `/commit` owns that).
  `/celebrant` expects the feature branch already committed and refuses a dirty tree.
- Squash or rebase merges — the skill makes a `--no-ff` merge commit by design.
- Opening or closing PRs/MRs — `/celebrant` operates on local + remote branches,
  not on the forge.

## Implementation surface

- One new skill: `skills/celebrant/SKILL.md` (frontmatter `user_invocable: true`,
  a `description` matching the family's voice).
- No new hook: the flow is plain sequential git the skill drives step by step;
  `git:*` is already permitted, so no permission-prompt risk that would warrant
  extracting a script.
- Propagate with `/install` (never `./install.sh` directly), so every configured
  root receives the skill.

## Acceptance

- On a committed feature branch, `/celebrant` merges it into the resolved default
  branch with a `--no-ff` merge commit, pushes, and deletes the branch local +
  remote — after one confirm.
- On a repo whose default is `develop`/`dev` (per `base_branch.md`), the merge
  targets that branch, not `master`.
- A dirty working tree, or invoking while already on the target, is refused
  before any branch changes.
- The pre-merge gate runs `/argonath --quick` by default and the full `/argonath`
  under `--full`; a Hold warns rather than hard-stops.
