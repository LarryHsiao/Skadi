---
name: No positional boolean flags
scope: [diff, project]
---

A bare `true` or `false` at a call site, with no label, tells the reader nothing about what the flag means. `connect(host, true, false)` reads as ceremony; `connect(host, retry: true, dryRun: false)` reads as intention. Named arguments are the floor; two methods named for what they do, or an enum, climb higher when the flag bifurcates behaviour.

**Prefer the project's own analyzer.** When the language affords a direct lint for this concern, its diagnostics are authoritative:

- Dart / Flutter: enable `avoid_positional_boolean_parameters` in `analysis_options.yaml` (already in `package:flutter_lints` and `package:lints/recommended`). The rule catches the declaration; combined with Dart's named-argument syntax, the call site follows.
- Swift: the language requires labelled arguments by default; a positional bool at a call site usually means the parameter was declared with an explicit `_` label. Flag any such declaration.
- TypeScript / JavaScript: no direct ESLint rule, but `eslint-plugin-boolean-prop-naming` covers React props, and custom `no-restricted-syntax` rules can match `CallExpression > Literal[value=true]` patterns where the codebase has chosen to enforce it.
- Python: `flake8-boolean-trap` flags positional boolean defaults and calls.
- Kotlin: no built-in Detekt rule; some teams add a custom rule via ktlint or Detekt's `forbidden-pattern`.
- Rust, Go, C / C++: no analyzer signal — these languages have no named-argument syntax, so the convention is enum or options-struct instead. The check applies only where the codebase has chosen that convention.

If the analyzer is wired and reports cleanly, its verdict stands.

**Fallback pattern** — when no analyzer covers it, grep call sites for an unlabelled boolean literal in argument position:

- A function call whose argument list contains a bare `true` or `false` **not preceded by an argument name** — i.e. *not* `name: true` (Dart, Swift, Ruby), `name=true` (Python, C#), or the equivalent labelled form in the project's language.
- The call must have **at least one other argument** beyond the bool — a sole-argument call like `isActive(true)` reads as a query and does not obscure intent.

Special cases that do **not** count:

- Test code where a small helper is exercised with both branches (`f(true)` and `f(false)` on consecutive lines, in a `*_test.*` / `*.test.*` / `*_spec.*` file).
- Language built-ins where the convention is universal and unambiguous (`map.set(key, true)` in JS-style sets, `arr.sort(undefined, true)` reverse-sort idioms, `regex.match(s, true)` case-insensitive shortcuts).
- Languages without named-argument syntax (Rust, Go, C, plain JS) when the codebase has not opted into an enum / options-struct convention — the rule does not bind where the language does not afford the better shape.

The fallback errs on the side of false positives in languages without named-arg syntax; the human reviewing the rider's output decides which findings count.

**When the target is a diff** — flag changes that *introduce* a positional bool flag call:

- Pass when the diff adds no new such call, or replaces an existing one with a named-argument, enum, or split-method form.
- Fail when the diff adds a new multi-argument call with an unlabelled `true` or `false`.

A pre-existing positional bool the diff merely touches is project-scope debt, not a diff-scope failure.

**When the target is a project root** — survey the standing tree:

- Pass when the analyzer is wired and reports clean, or the fallback grep finds no matches.
- Fail otherwise.

Cap fallback findings at the first ten matches.

n/a when:

- The project contains no source code in any recognised language.
- The project is written entirely in a language without named-argument syntax **and** has not opted into an enum / options-struct convention — the rule does not bind where the language does not afford the better shape.
- The diff scope is non-empty but touches only non-code files.

On fail, name each finding as `file:line — <signature snippet>` (the call site's bare bool, e.g. `lib/client.dart:42 — connect(host, true, false)`). Quote no more than the offending line itself.

See `~/.claude/docs/style/general.md` § Maintainability for the authoring-time framing of the same concern.
