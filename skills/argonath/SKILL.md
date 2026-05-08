---
name: argonath
description: Use when the user runs /argonath [--quick]. Runs the project's lint/build/test toolchain on the current repo, scans the about-to-be-pushed diff for secrets, then invokes /nazgul and /mithrandir as advisory rows. Aggregates everything into one Pass / Hold verdict. Report only — never runs `git push`.
user_invocable: true
---

# Argonath — Pre-Push Analysis

The twin pillars at the river-gate. Before code crosses, render a verdict on whether it should pass. Report only — the skill never invokes `git push` itself.

## Argument Parsing

Arguments: `/argonath [--quick]`

- No args → full run (artefacts + secrets + advisory rows from /nazgul and /mithrandir).
- `--quick` → skip the two advisory rows. Faster; only artefact commands and the secret scan.

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

Returns JSON: `{stack, lint, build, test, test_scope, source}`. If `stack` is `unknown` and every command is empty, render every artefact row as `⚪ skipped — no command`, run the secret scan and advisory rows, and finish.

When `source` is `override` or `merged`, append `(via .skadi/argonath.yaml)` after the stack name in the header.

### 3. Run artefact steps

For each non-empty command (`lint`, `build`, `test`), call:

```bash
~/.claude/hooks/argonath-run.sh <label> <command...>
```

Labels: `Lint`, `Build`, `Tests`. Capture each JSON result. The hook always exits 0; read `ok` from the JSON.

Empty command → render the row as `⚪ skipped — no command`.

If `test_scope` is `changed`, the project's test command runs as configured — Argonath does not transform it. The override file is the place to express scope.

### 4. Secret scan

```bash
~/.claude/hooks/argonath-secrets.sh
```

Returns JSON `{ok, count, hits, note}`. The diff range scanned is `@{upstream}..HEAD` (or `HEAD` if no upstream).

### 5. Advisory rows (skip when `--quick`)

Invoke the two existing skills as sub-skills via the Skill tool, but fold each into a single row only.

- **Rubric** — invoke `/nazgul` (default verb, scope=diff). Read its pass/fail tally; render `<P> pass · <F> fail`.
- **Verdict** — invoke `/mithrandir branch`. Read the tier (`sound` / `wavering` / `off`) and the one-line reasoning paragraph; render `<tier> — <≤60-char excerpt>`.

If either errors out, render its row as `⚠  unavailable — <short reason>` and continue.

### 6. Aggregate

- **Pass** — every artefact step `ok` or `skipped`, **and** secret scan returned `ok: true`.
- **Hold** — any artefact step `ok: false`, **or** secret scan returned `ok: false`.

Advisory rows (rubric, mithrandir) **never** push the verdict off `Pass`.

### 7. Render

Lead with a blockquote summary line, then the table. The blockquote echoes the verdict so the reader gets the conclusion in one breath.

```
> Hold — tests must pass before crossing.

Argonath  master · 3 commits ahead of origin/master · stack: flutter
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Lint            fvm flutter analyze            0 issues
  ✅ Build           fvm flutter build apk --debug  ok
  🚫 Tests           fvm flutter test               4 failing in test/dos_step3_test.dart
  ✅ Secret scan     no tokens / .env values in diff
  ✅ Rubric          /nazgul: 9 pass · 0 fail
  ⚠  Verdict        /mithrandir: wavering — proportion drifts wide
───────────────────────────────────────
  3 of 4 gates clear · 1 advisory note
```

Symbols:

- `✅` — passed (`ok: true`)
- `🚫` — failed (`ok: false`)
- `⚪` — skipped (no command, or `--quick` mode for advisory rows)
- `⚠ ` — advisory tier below `sound` / unavailable

Header line carries: `<branch> · <ahead-state> · stack: <stack>` and `(via .skadi/argonath.yaml)` when relevant.

`<ahead-state>`:
- `<N> commits ahead of <upstream>` when `N > 0`
- `up to date with <upstream>` when `N == 0`
- `no upstream` when not tracking

Footer line: `<P> of <T> gates clear · <A> advisory note(s)` — counts only the artefact + secret rows toward the gate count; advisory rows are tallied separately.

Verdict-summary line in the blockquote follows /mithrandir's spirit:

- `> Pass — every gate clear, the road is open.`
- `> Hold — <plain reason: tests must pass / secrets removed / both>.`

When `stack: unknown` and every artefact row was skipped, the verdict still resolves on the secret scan alone. If clean: `> Pass — toolchain unknown, but no obstacles found.`

## Rules

- Read-only — never runs `git push`, `git commit`, `git tag`, `git push --tags`, or any state-mutating tool beyond the artefact commands themselves
- Artefact commands are taken at the user's word — if `.skadi/argonath.yaml` configures something destructive as the test command, the skill runs it; the override file is the user's responsibility
- The full step log lives in the tempfile path emitted by `argonath-run.sh`. Do not read it unless the user asks for the failure detail
- Sub-skills (`/nazgul`, `/mithrandir`) are advisory — never block the Pass/Hold verdict on their findings
- Sort the body rows in the order: Lint → Build → Tests → Secret scan → Rubric → Verdict. Hide a row only if it is `--quick`-suppressed
