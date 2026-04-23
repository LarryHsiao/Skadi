---
name: nazgul
description: Use when the user runs /nazgul. Dispatches the Nine — one agent per check file — to inspect a code target (default — uncommitted changes) and aggregates pass/fail/n/a verdicts into a single table. Checks live as markdown files under `checks/`; project-local overrides take precedence. Audit only — never fixes, commits, or files issues on its own.
user_invocable: true
---

# Nazgûl

Calls the riders out. Each check is a small markdown file; each file becomes a separate agent, sent forth in parallel against a chosen code target. Every rider returns a single line — `pass | fail | n/a` and a short note — and the parent gathers them into one table.

Nazgûl is an **auditor**. It finds and names; it does not mend, commit, push, or file issues. What is done with the findings is the user's word, handed off to other skills when needed.

## Workflow

### 1. Resolve target

If the user passed an argument, use it. Otherwise default to **uncommitted changes**.

| Argument | How to capture the diff |
|----------|--------------------------|
| (none) — **uncommitted** | `git diff HEAD` plus, for each untracked path from `git ls-files --others --exclude-standard`, a synthetic `+++` block of its contents |
| `branch` | `git diff $(git merge-base HEAD <base>)..HEAD`, where `<base>` is the first of `master`, `main`, `origin/HEAD` that resolves |
| `<sha>` | `git show <sha>` |
| `<sha1>..<sha2>` | `git diff <sha1>..<sha2>` |

Capture the diff **once** and hold it as `DIFF`. If the diff is empty, tell the user and stop — do not summon the riders to an empty field.

**Delivery to riders.** If `DIFF` is under 500 lines, pass it inline in each agent prompt. Otherwise write it once to `build/nazgul/diff-<timestamp>.patch` and pass the path instead. Create `build/nazgul/` if absent.

### 2. Read the roll

The checklist is a folder of markdown files, searched in this order:

1. `.skadi/nazgul/checks/*.md` in the project root (project-local override).
2. `<skill-dir>/checks/*.md` (the default roll, shipped with the skill).

The first folder that exists and holds at least one `*.md` wins; the other is ignored (no merging). If neither folder exists or both are empty, tell the user there are no checks configured and stop.

Each check file has YAML frontmatter and a prompt body:

```markdown
---
name: No commented-out code
agent: Explore        # optional; default Explore
autofix: false        # optional; reserved for future --fix flag
---

Flag any commented-out code blocks introduced in the diff. If a
commented block documents intent or explains alternatives, note
it but pass. Otherwise fail with file:line of the commented block.
```

- `name` — shown in the report table. Required.
- `agent` — subagent type to dispatch. Default `Explore` (read-only, lighter). Escalate to `general-purpose` only when the check genuinely needs broader tools.
- `autofix` — reserved flag for a future `--fix` mode. Ignore it for now.

Assign each check an **index** starting at 1, in stable filename-sorted order. The index travels with the rider to the reply.

### 3. Summon the riders

Dispatch one **Agent** call per check, **all in a single message**, so they ride in parallel.

Each agent prompt must contain, and in this order:

1. The rider's identity: `You are rider #<N> of /nazgul: "<check name>".`
2. The target: either the inline `DIFF`, or `The diff is at <path>. Read it first.`
3. The prompt body from the check file, verbatim.
4. The reply shape, exactly:

   > Reply with exactly one line and nothing else:
   > `<N>|<status>|<note>`
   > where `<status>` is one of `pass`, `fail`, `n/a`,
   > and `<note>` is a short human-readable reason, no pipes.
   > No preamble. No markdown. No code fences. No trailing newline of explanation.

Riders may read any file in the tree when context is needed beyond the diff. Riders must never write, edit, commit, push, or file issues — they are auditors.

Give each rider a **timeout of 60 seconds**. A rider that errors or times out yields a `?` row in the report.

### 4. Aggregate

Parse each reply by splitting on the first two `|` characters — so notes containing `|` are preserved. Validate: the first field must match the rider's assigned index; the second must be `pass`, `fail`, or `n/a`; reject anything else as malformed.

Print one table:

| # | Check | Status | Note |
|---|-------|--------|------|
| 1 | … | one of ✅ pass / ❌ fail / — n/a / ? | … |

One glyph per row, not three. End with:

> **N failed / M checks** — where M counts every rider, including n/a and ?.

For any row marked `?` or malformed, print the raw reply in a fenced block below the table so the cause can be seen.

### Example output

```
| # | Check                          | Status  | Note                                  |
|---|--------------------------------|---------|---------------------------------------|
| 1 | No commented-out code          | ✅ pass | nothing flagged                        |
| 2 | No new TODOs without owner     | ❌ fail | src/app.ts:42 — "TODO: fix later"      |
| 3 | Imports alphabetised           | — n/a   | no import changes in diff              |

1 failed / 3 checks
```

## After the report

The knight's duty ends at the table. Follow-through is the user's to command:

- **To fix a finding** — say so, and I reach for Edit. Or, for mechanical cases, a future `/nazgul --fix` flag will invoke only checks whose frontmatter declares `autofix: true`. Not built yet; named so the shape is known.
- **To file a finding as an issue** — invoke `/jira create` or `gh issue create` directly. A future `/nazgul --file-issues` flag may chain this. Not built yet.
- **To do neither** — the default. Fix the flaw before the next commit and rerun `/nazgul` to confirm.

## Checks

The default roll lives at `<skill-dir>/checks/*.md`. Each file is one check, as shown in step 2.

A repository may override the roll by placing its own files under `.skadi/nazgul/checks/*.md` at the project root. When that folder exists and holds any file, it replaces the default entirely — no merging. This lets a project tune the riders to its own code without touching the global skill.

## Promoting a check

If a check proves worth summoning on its own:

1. Copy `checks/<name>.md` to `skills/<name>/SKILL.md`.
2. Replace the check frontmatter with skill frontmatter — add `user_invocable: true` and a `description` field that will read well in the skill listing.
3. Prepend a small harness: resolve the target (step 1 above), dispatch a single agent with the prompt body, print the one-line verdict.

The prompt body — the truth of the check — does not change in the promotion.

## Rules

- Dispatch all riders in a single message. Parallel always; never sequential.
- Riders may read any file in the tree; riders must never write, edit, commit, push, or open a PR.
- If the diff is empty, tell the user and stop. Do not summon the Nine to an empty field.
- Reserve the riders for judgment. If grep or a linter can settle the matter, it is not a check.
- Nazgûl itself never commits, pushes, opens PRs, or files issues. Those actions belong to the user or to other skills the user invokes after the report.
