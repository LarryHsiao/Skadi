---
name: Nesting under control
scope: [diff, project]
---

Deep control-flow nesting forces the reader to carry the whole condition chain in their head. A method four levels deep is rarely doing one thing — more often it is two or three things tangled, and the cleave wants extracting. The cap is three indents; the fourth is the alarm bell.

**Prefer the project's own analyzer.** Most languages have a configurable nesting or cognitive-complexity rule already; if the project's lint config enables one, its diagnostics are authoritative:

- Dart / Flutter: `dart_code_metrics` with `nesting-level: 3`; or `analysis_options.yaml` enabling the `nesting-level` metric.
- TypeScript / JavaScript: ESLint `max-depth` rule (default 4 — set to 3 to enforce the cap above).
- Rust: clippy `excessive_nesting` lint, or `cognitive_complexity` threshold.
- Go: `golangci-lint` with `nestif` enabled, or `gocyclo` for cyclomatic complexity.
- Python: `ruff check --select C901` (mccabe complexity); `flake8-cognitive-complexity` for nesting specifically.
- Swift: SwiftLint `cyclomatic_complexity` (the closest available; the built-in `nesting` rule covers type nesting, not control flow).
- Kotlin: Detekt `NestedBlockDepth` (default threshold 4 — lower to 3 to match the cap).

If the analyzer is wired and reports cleanly, its verdict stands. The rider need not re-derive what the tool already flags.

**Fallback pattern** — when no analyzer is configured, scan by leading whitespace:

- Identify each function / method block (heuristic: a line ending in `{` for braced languages; matching `def …:` or `func …` for indent-driven languages).
- Within the block, measure the maximum interior indent depth in language-native units (tabs, four-space groups, Python `INDENT` tokens). The block's own opening counts as level 0.
- A block whose maximum interior depth reaches **four or more levels** trips the check.

Continuations of a multi-line expression do **not** count as nesting — only fresh blocks (`if`, `for`, `while`, `try`, `match`, closures with bodies, anonymous functions). When in doubt, lean conservative; a borderline finding is better than a missed real one in a fallback pass.

**When the target is a diff** — flag changes that introduce or deepen nesting:

- Pass when the diff adds no new 4+-level nest, or refactors an existing one shallower.
- Fail when the diff adds a function whose maximum interior depth crosses the cap (3 → 4+), or amends an existing function to that effect.

A pre-existing 4+ nest the diff merely touches (without deepening) is **not** a regression — it is project-scope debt, not a diff-scope failure.

**When the target is a project root** — survey the standing tree:

- Pass when no function exceeds three levels of interior nesting (analyzer-clean, or fallback-clean).
- Fail when at least one function exceeds the cap.

Cap fallback findings at the first ten matches; a richer signal belongs in the analyzer.

n/a when:

- The project contains no source code in any recognised language.
- The diff scope is non-empty but touches only non-code files.

On fail, name each finding as `file:line — depth=N`, where `line` is the deepest indent's location and `N` is the indent count (e.g. `lib/client.dart:62 — depth=5`). Quote no more than the offending line itself; do not echo the full function body.

See `~/.claude/docs/style/general.md` § Maintainability for the authoring-time framing of the same concern.
