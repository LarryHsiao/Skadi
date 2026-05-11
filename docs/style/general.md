# Code Style Guide

> Language- or framework-specific rules belong in their own style file, not here.

## Naming

- **No `-er` suffix** for classes or packages (no `Manager`, `Helper`, `Handler`, `Processor`, etc.). Name things after the domain concept they represent.
- **Classes and objects are nouns.** If you can't name it without a verb, it's probably a method, not a class.
- **Methods are verbs.** They do things.

## Methods

- Keep methods under 25 lines. If it grows beyond that, extract smaller private methods.

## Tests

- **New code lands with a test.** Every new function, class, or branch carries a test that exercises its behavior. The test is part of the change, not a follow-up.
- **Modification is the moment to pay the test debt.** When editing existing code that bears no test, add one as part of the change. Touching untested code without leaving a test behind is how the debt compounds; the edit is the natural occasion to settle it.
- **State the expectation, then test the result.** Each test names the expected outcome explicitly — a `final expected = ...` (or the language's equivalent) declared before the unit is exercised — and the assertion compares the actual result against that named value. Inline literals buried inside an `expect`/`assertEquals` call obscure intent; a named expectation reads as the test's contract.
- **Cycle code and test until the result matches the plan.** Write a slice of the change, run its test, read the result. If it diverges from what the plan called for, return to the code; do not bend the test to fit the slip. The loop closes only when the test produces the result the plan named (the plan being whatever names the expected outcome — a `[COUNSEL]` body, an issue's acceptance criteria, or the agreement reached in chat). Each branch the slice carries earns its own test naming the expected outcome of that branch — the happy path is the first, error returns and boundaries (empty container, null fallback, failure return, throw) follow. A one-branch slice needs one test; a three-branch slice needs three.

## General-purpose code

- When editing a file meant to be a general-purpose widget (a shared component, a utility, a base class), do not add domain-specific logic. Keep it general. If the change needs domain knowledge, lift it to the caller — leave the widget unaware.

## Dependencies

- **No references that wander outside the source tree.** A dependency must resolve from inside the repository or from a published registry (pub.dev, npm, Maven Central, PyPI, a git URL, and the like). A path that climbs out of the project root — Flutter's `path: ../other_project` in `pubspec.yaml`, npm's `"file:../sibling"`, Gradle's `includeBuild('../lib')`, a Python editable install of `../pkg` — is forbidden. Such a path resolves only on the author's machine; on any other clone the sibling directory is absent and the build breaks on first pull. If the code is shared, publish it (registry, git tag, monorepo workspace within this repo); if it is not, vendor it in. Never lean on the filesystem layout of one developer's laptop.

## Indexing

- **Guard every index access against an empty container.** Before `xs[0]`, `xs.first`, `xs.last`, or `xs[i]`, check the length or use a safe accessor (`xs.firstOrNull`, `xs.elementAtOrNull(i)`, pattern destructuring with a fallback). The empty list is the common pitfall — `xs[0]` on `[]` raises, not returns null. The same care applies to map lookups, regex match groups, and argument arrays.