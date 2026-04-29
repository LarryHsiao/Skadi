---
name: Coverage held by the diff
scope: diff
---

If the project measures test coverage, a diff must not drop it. An auditor agent cannot actually run tests and compute coverage — it is read-only. So this check uses a heuristic: detect coverage *tooling* in the project, then flag diffs that add or change first-party source without any commensurate test change.

Detect coverage tooling (any one is enough):

- A coverage badge in `README.md` pointing at codecov, coveralls, or `shields.io/.../coverage`.
- `.codecov.yml` or `codecov.yml` at the project root.
- A CI workflow step invoking coverage (e.g. `flutter test --coverage`, `jest --coverage`, `vitest run --coverage`, `pytest --cov`, `go test -cover`, `cargo tarpaulin`, `cargo llvm-cov`).
- A checked-in `coverage/lcov.info`, `coverage/coverage-summary.json`, `coverage.xml`, or similar report.

n/a when:
- No coverage tooling is detected anywhere in the project.

Pass when:
- The diff modifies no first-party source files (only docs, config, build files, or tests themselves).
- OR the diff modifies source files AND adds or modifies test files that touch the same modules / packages / features.

Fail when:
- The diff adds new source files or changes source logic, AND no test files are added or modified to cover the change.

Heuristic notes:

- "First-party source" means project code under the conventional source roots (`lib/`, `src/`, `app/`, `pkg/`, language-appropriate equivalents). Skip vendored, generated, and third-party paths.
- Trivial source changes — comment-only edits, formatting, renaming a private symbol with no behaviour change — pass without test churn.
- A cluster of small source changes touching the same module is one cluster, not many; one matching test edit can cover the cluster.

On fail, name the source files that gained logic without tests, plus the detected coverage tooling so the user knows which signal triggered the rule.
