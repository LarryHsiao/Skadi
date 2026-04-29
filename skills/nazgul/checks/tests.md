---
name: Automated tests present
scope: project
---

A foundation project has automated tests running under the language's standard test runner. Without them, regressions go unseen.

Scan the project root for a tests location. The shape varies by language:

- Flutter / Dart: `test/` with at least one `*_test.dart`.
- TypeScript / JavaScript: `__tests__/`, `test/`, `tests/`, or `*.test.{js,ts,jsx,tsx}` / `*.spec.{js,ts,jsx,tsx}` co-located with sources.
- Go: `*_test.go` files alongside the packages.
- Rust: `tests/` directory and/or `#[test]` items inside `src/`.
- Python: `tests/` directory with `test_*.py` files, or `*_test.py` co-located.
- Swift: `Tests/` directory with `XCTestCase` subclasses.
- Kotlin: `src/test/` or `src/androidTest/` with `@Test` annotated methods.

Pass when:
- A tests directory or co-located test files exist with at least one test in the project's primary language.

Fail when:
- No test files are found in any recognised shape for the language.

n/a when:
- The project contains no source code in a testable language (documentation- or asset-only repository).

On fail, name the directories searched and the nearest miss (e.g. "no `test/` at project root; `lib/` contains 47 `*.dart` files").
