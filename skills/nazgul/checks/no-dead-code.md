---
name: No dead code
scope: [diff, project]
---

Dead code is the silent debt — unread, untested, and yet binding the maintainer to keep it compiling. An unused import shifts costs every build; an unreachable branch lies to the next reader about what the function does; a commented-out block hints at a decision long since forgotten. The check sweeps for what the project has the means to detect, and falls back to plain pattern-reading where no tool is configured.

**Prefer the project's own analyzer.** Most languages already flag dead code through the lint configuration the `static-analyze` check enforces. Run the analyzer once over the target and read its findings as the authoritative signal:

- Dart / Flutter: `dart analyze` (or `fvm dart analyze`) — surfaces `dead_code`, `unused_import`, `unused_local_variable`, `unused_element`, `unused_field`.
- TypeScript / JavaScript: `tsc --noEmit --noUnusedLocals --noUnusedParameters`, or ESLint with `no-unused-vars` / `@typescript-eslint/no-unused-vars`. For orphan files / exports: `knip`, `ts-prune`, `unimported`.
- Rust: `cargo check` (warns on unused imports / functions / variables); `cargo +nightly udeps` for unused dependencies; `cargo machete` for the same on stable.
- Go: `staticcheck`, `golangci-lint run --enable=unused,deadcode`.
- Python: `ruff check --select F401,F811,F841` (unused import / redefinition / unused variable); `vulture` for unreachable code and unused symbols.
- Swift: SwiftLint with `unused_declaration`, `unused_import`, `dead_code` rules enabled.
- Kotlin: Detekt with `UnusedPrivateMember`, `UnusedImports`, `UnreachableCode` rules.

If the analyzer is wired and runs cleanly, its diagnostics are the verdict. The rider need not re-derive what the tool already says.

**Fallback patterns** — when no analyzer is configured for the project's language, or the analyzer runs but does not cover the kinds below, scan the target by hand:

- **Code after a non-returning statement.** Lines following `return`, `throw`, `break`, `continue`, `exit()`, `process.exit(...)`, `panic!(...)`, `os.exit(...)` on the same control-flow path with no label or fall-through above them.
- **Always-false branches.** `if (false) { … }`, `if (0) { … }`, `if constexpr (false)`, `while (false)`, `#if 0 … #endif`, conditions like `if (1 == 0)` or `if (!true)`.
- **Large commented-out code blocks.** Four or more consecutive lines that read as commented source (line comment prefix on each line, or one fenced `/* … */` block, where the inside parses as plausible code in the surrounding language). A single-line `// TODO`, `// FIXME`, `// note: …`, or copyright header does not count.
- **Empty unused declarations.** A private function whose body is `pass` / `{}` / nothing, declared and never referenced in the same file.

The fallback is best-effort; it is meant to catch the obvious cases the analyzer would have flagged had it been configured. It is not a substitute for a real lint.

**When the target is a diff** — flag dead code **introduced or amplified** by the change:

- Pass when the diff adds no new dead-code patterns, or removes existing ones.
- Fail when the diff adds any of:
  - An import / use / require for a symbol not referenced anywhere in the changed files (and the project does not separately export the symbol).
  - A line that becomes unreachable because of a statement the diff adds above it.
  - A new always-false branch, or new code inside one.
  - A new commented-out code block of four or more lines.
  - A new private function, method, or field with no call site visible in the same file.

Do **not** fail on dead code that existed before the diff and the diff merely touched the surrounding file — that is pre-existing debt for the `project` scope, not a regression on this change.

**When the target is a project root** — survey the standing tree:

- Pass when the project's analyzer runs to completion with no dead-code diagnostics, **or** the fallback scan finds no plain patterns above.
- Fail when the analyzer reports any dead-code diagnostic, or the fallback finds at least one plain match.

Cap fallback findings at the first ten matches per pattern — a richer signal belongs in the analyzer.

n/a when:

- The project contains no source code in any recognised language (documentation- or asset-only repository).
- The diff scope is non-empty but touches only non-code files (READMEs, asset binaries, JSON config without logic, lockfiles).

On fail, name each finding as `file:line — <kind>` with a four-word note (e.g. `lib/foo.dart:42 — unreachable after return`, `src/util.ts:8 — unused import 'lodash'`). Quote no more than the offending line itself; do not echo full function bodies.
