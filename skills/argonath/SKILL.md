---
name: argonath
description: Use when the user runs /argonath [project] [--quick]. Default mode weighs the about-to-be-pushed diff; the `project` verb weighs the standing project tree instead. Runs the project's lint/format/build/test toolchain, scans for secrets, then invokes /nazgul and /mithrandir as advisory rows. Aggregates everything into one Pass / Hold verdict. Report only — never runs `git push`.
user_invocable: true
---

# Argonath — Pre-Push Analysis

The twin pillars at the river-gate. Before code crosses, render a verdict on whether it should pass. Report only — the skill never invokes `git push` itself.

## Argument Parsing

Arguments: `/argonath [project] [--quick]`

- No verb → diff mode. Weighs the about-to-be-pushed diff (`@{upstream}..HEAD`). Full run includes artefacts + secret scan + advisory rows.
- `project` verb → project mode. Weighs the standing project tree, not a diff. Useful on master/main, on a fully pushed branch, or when no commits have been made yet.
- `--quick` → skip the two advisory rows in either mode. Faster; only artefact commands and the secret scan.

## Workflow

### 1. Verify a git repo

```bash
git rev-parse --show-toplevel
```

If it errors, stop:
> Not in a git repo — nothing to analyse.

Capture branch and upstream:

```bash
git rev-parse --abbrev-ref HEAD
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
git rev-list --count '@{upstream}..HEAD'
```

If no upstream is configured, mark the header `· no upstream`.

### 2. Resolve commands

```bash
~/.claude/hooks/argonath-detect.sh
```

Returns JSON: `{stack, lint, format, build, test, test_scope, source}`. If `stack` is `unknown` and every command is empty, render every artefact row as `⚪ skipped — no command`, run the secret scan and advisory rows, and finish.

When `source` is `override` or `merged`, append `(via .skadi/argonath.yaml)` after the stack name in the header.

### 3. Run artefact steps

For each non-empty command (`lint`, `format`, `build`, `test`), call:

```bash
~/.claude/hooks/argonath-run.sh <label> <command...>
```

Labels: `Lint`, `Format`, `Build`, `Tests`. Capture each JSON result. The hook always exits 0; read `ok` from the JSON.

The `format` command is a **check**, not a fix — it carries `--set-exit-if-changed`, so it exits non-zero when files are unformatted and the row fails. Argonath never rewrites the tree it grades.

Empty command → render the row as `⚪ skipped — no command`.

If `test_scope` is `changed`, the project's test command runs as configured — Argonath does not transform it. The override file is the place to express scope.

### 4. Secret scan

Diff mode:

```bash
~/.claude/hooks/argonath-secrets.sh
```

Project mode:

```bash
~/.claude/hooks/argonath-secrets.sh --project
```

Returns JSON `{ok, count, hits, note}`. In diff mode the scanned range is `@{upstream}..HEAD` (or `HEAD` if no upstream); in project mode every tracked file is scanned, untracked / `.gitignore`d paths excluded.

### 5. Advisory rows (skip when `--quick`)

Invoke the two existing skills as sub-skills via the Skill tool, but fold each into a single row only.

- **Rubric** —
  - Diff mode → invoke `/nazgul` (default verb, scope=diff). Read its pass/fail tally; render `<P> pass · <F> fail`.
  - Project mode → invoke `/nazgul project`. Same row shape.
- **Verdict** —
  - Diff mode → invoke `/mithrandir branch`. Read the tier (`sound` / `wavering` / `off`) and the one-line reasoning paragraph; render `<tier> — <≤60-char excerpt>`.
  - Project mode → `/mithrandir` has no project verb, so render the row as `⚪ skipped — no project mode`.

If either errors out, render its row as `⚠  unavailable — <short reason>` and continue.

### 6. Aggregate

- **Pass** — every artefact step `ok` or `skipped`, **and** secret scan returned `ok: true`.
- **Hold** — any artefact step `ok: false`, **or** secret scan returned `ok: false`.

Advisory rows (rubric, mithrandir) **never** push the verdict off `Pass`.

### 7. Render

Lead with a blockquote summary line, then the table. The blockquote echoes the verdict so the reader gets the conclusion in one breath.

Diff mode:

```
> Hold — tests must pass before crossing.

Argonath  master · 3 commits ahead of origin/master · stack: flutter
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Lint            fvm flutter analyze                          0 issues
  ✅ Format          fvm dart format --set-exit-if-changed .      clean
  ✅ Build           fvm flutter build apk --debug                ok
  🚫 Tests           fvm flutter test                             4 failing in test/dos_step3_test.dart
  ✅ Secret scan     no tokens / .env values in diff
  ✅ Rubric          /nazgul: 9 pass · 0 fail
  ⚠  Verdict        /mithrandir: wavering — proportion drifts wide
───────────────────────────────────────
  4 of 5 gates clear · 1 advisory note
```

Project mode:

```
> Pass — project tree clear, no obstacles found.

Argonath  master · up to date with origin/master · stack: flutter · mode: project
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Lint            fvm flutter analyze                          0 issues
  ✅ Format          fvm dart format --set-exit-if-changed .      clean
  ✅ Build           fvm flutter build apk --debug                ok
  ✅ Tests           fvm flutter test                             all green
  ✅ Secret scan     no tokens / .env values in tracked files
  ✅ Rubric          /nazgul project: 9 pass · 0 fail
  ⚪ Verdict         skipped — no project mode
───────────────────────────────────────
  5 of 5 gates clear · 1 advisory note
```

Symbols:

- `✅` — passed (`ok: true`)
- `🚫` — failed (`ok: false`)
- `⚪` — skipped (no command, or `--quick` mode for advisory rows)
- `⚠ ` — advisory tier below `sound` / unavailable

Header line carries: `<branch> · <ahead-state> · stack: <stack>` and `(via .skadi/argonath.yaml)` when relevant. In project mode, append ` · mode: project` after the stack name so the scope is plain.

`<ahead-state>`:
- `<N> commits ahead of <upstream>` when `N > 0`
- `up to date with <upstream>` when `N == 0`
- `no upstream` when not tracking

Footer line: `<P> of <T> gates clear · <A> advisory note(s)` — counts only the artefact + secret rows toward the gate count; advisory rows are tallied separately.

Verdict-summary line in the blockquote follows /mithrandir's spirit:

- Diff mode:
  - `> Pass — every gate clear, the road is open.`
  - `> Hold — <plain reason: tests must pass / secrets removed / both>.`
- Project mode:
  - `> Pass — project tree clear, no obstacles found.`
  - `> Hold — <plain reason>.`

When `stack: unknown` and every artefact row was skipped, the verdict still resolves on the secret scan alone. If clean: `> Pass — toolchain unknown, but no obstacles found.`

## Rules

- Read-only — never runs `git push`, `git commit`, `git tag`, `git push --tags`, or any state-mutating tool beyond the artefact commands themselves
- Artefact commands are taken at the user's word — if `.skadi/argonath.yaml` configures something destructive as the test command, the skill runs it; the override file is the user's responsibility
- The full step log lives in the tempfile path emitted by `argonath-run.sh`. Do not read it unless the user asks for the failure detail
- Sub-skills (`/nazgul`, `/mithrandir`) are advisory — never block the Pass/Hold verdict on their findings
- Sort the body rows in the order: Lint → Format → Build → Tests → Secret scan → Rubric → Verdict. Hide a row only if it is `--quick`-suppressed
- Project mode scans tracked files only — untracked / `.gitignore`d paths stay out of the secret scan, and the verdict row is always `⚪ skipped` (no `/mithrandir` project verb exists)
