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
- **Cycle code and test until the result matches the plan.** Write the test first, run it, and watch it fail for the reason the plan names — feature missing, branch unexercised, return malformed. A test that passes the moment it is written has not earned its place; it may be testing something else, or nothing at all. Only once the failure mode is the one expected, write the slice of change to make it green, run it again, and read the result. If the result diverges from what the plan called for, return to the code; do not bend the test to fit the slip. The loop closes only when the test produces the result the plan named (the plan being whatever names the expected outcome — a `[COUNSEL]` body, an issue's acceptance criteria, or the agreement reached in chat). Each branch the slice carries earns its own test naming the expected outcome of that branch — the happy path is the first, error returns and boundaries (empty container, null fallback, failure return, throw) follow. A one-branch slice needs one test; a three-branch slice needs three.
- **Keep path expectations platform-agnostic.** A test that hard-codes `/` in an expected path passes on the author's POSIX machine and fails on a Windows runner, where the path library joins with `\`. Build the expected path with the same join the code uses — Dart's `p.join`, Node's `path.join`, Python's `os.path.join` — never a string literal bearing a chosen separator. The separator is the platform's to pick, not the test's to assume; a green local run on one OS does not vouch for the CI runner on another.

## General-Purpose Code

- When editing a file meant to be a general-purpose widget (a shared component, a utility, a base class), do not add domain-specific logic. Keep it general. If the change needs domain knowledge, lift it to the caller — leave the widget unaware.

## Mutability

- **Prefer `final` by default — fields, locals, parameters.** A variable that never reassigns reads as a single value, not a slot; an object whose fields never change cannot drift mid-call, so the reader need not track *which* call last touched it. Reach for mutability only when the object's identity *is* its changing state (a counter, a buffer, a cursor) — and even then, prefer rebuilding over mutating where the cost permits.

## Maintainability

Code is read more often than written. These rules guard the next reader against unearned cost.

- **No dead code.** Unused imports, unreachable branches after `return` / `throw` / `break`, always-false guards (`if (false) { … }`, `#if 0`), private functions or fields with no call site, large commented-out blocks (four or more lines reading as paused source) — remove them. If a block is paused for "maybe later", it belongs in git history, not in the file.
- **Remove the superseded path; do not layer over it.** When a change replaces an existing path, delete it rather than adding a compatibility shim, a version branch, or a migration to carry the old shape forward — *where the code has no consumer beyond this repo*. Where a published API, a shipped client, or a deployed database depends on the old shape, compatibility is a requirement and not a courtesy: name the constraint plainly and keep the path. This governs supersession, not resilience — a fallback that supplies a default when a source fails is craft, not a compatibility layer.
- **Cap nesting at three indents.** When a method runs four-plus levels deep, the reader carries the whole condition chain in their head. Extract the inner work into a private method, or invert with an early return. Three is a soft cap — pass through it when the logic genuinely will not cleave; name plainly when it does.
- **Name your literals.** `86400`, `"premium"`, hard-coded thresholds and sentinel strings have the value on the page but not the intent. Lift them to a named constant — `static const secondsPerDay = 86400;` — so the call site reads as the thing it means. Exception: literals whose meaning is self-evident at the use site (`0`, `1`, the empty string for "no separator") need no name.
- **One name for one meaning; an enum for a closed set.** When the same string literal recurs for the same meaning — a status `"active"`, a mode `"dark"`, a key `"id"` — bind it once to a name rather than retyping the characters: a typo splits one concept into two the compiler cannot catch, and a rename must then chase every copy. When such strings form a *closed set* — the statuses a thing may hold, the modes it may run in — lift them to an enum, so the type names the whole range and the reader sees at a glance which values are legal; when the value stands alone with no siblings, a single named const suffices. The binding test is *meaning*, not spelling: two literals that read alike but mean different things — a `"name"` JSON key and a `"name"` column — stay apart, per *Lift duplicate shapes on the third recurrence* in [`universal.md`](universal.md).
- **No positional boolean-flag parameters at the call site.** `connect(true, false)` does not read; `connect(retry: true, dryRun: false)` (named arguments) does. When a flag genuinely bifurcates behavior, prefer two methods named for what each does — `connectWithRetry()` / `connectOnce()`. When the flag has three-plus states or a third is plausible, reach for an enum. When the choice deserves its own type, reach for a decorator or concrete per [`oo.md`](oo.md).
- **One abstraction level per method.** A method that orchestrates high-level steps next to byte-fiddling makes the reader context-switch mid-scroll. Lift the low-level work into a private method named for what it does; the outer method then reads as a sequence of intentions.
- **Keep comments honest.** A comment that contradicts the code, or that describes behaviour the code has outgrown, misleads the next reader more than no comment at all. When you edit code, edit its comments. When a `// TODO` or `// FIXME` has lost its referent or its urgency, remove it; otherwise update it to name what is actually still owed.
- **Duplication** is covered in [`universal.md`](universal.md) — it applies regardless of whose repo the code lives in, so it lives there rather than here.

## Indexing

- **Guard every index access against an empty container.** Before `xs[0]`, `xs.first`, `xs.last`, or `xs[i]`, check the length or use a safe accessor (`xs.firstOrNull`, `xs.elementAtOrNull(i)`, pattern destructuring with a fallback). The empty list is the common pitfall — `xs[0]` on `[]` raises, not returns null. The same care applies to map lookups, regex match groups, and argument arrays.

## Text Overflow

A field's width is fixed when the layout is drawn; the value it will hold is not. Decide what happens at that boundary before the boundary is met — the default is an **ellipsis**, but three kinds of field want three different answers.

- **Identity — names, titles, labels, row text, chips.** Ellipsis on one line. The prefix identifies the thing; the tail is decoration.
- **Prose — descriptions, messages, error text.** Wrap, then ellipsis at two or three lines. An ellipsed sentence loses its meaning outright, so it must be given room to say what it means first.
- **Exact values — money, identifiers, codes, dates, counts.** Never truncate; shrink the glyphs, wrap, or scroll. `$1,234,5…` does not read as *cut* — it reads as a smaller number, and a wrong answer is a correctness bug wearing a layout bug's clothes.

Two conditions bind the ellipsis wherever it is used:

- **The full value stays reachable** — a tooltip on the web, a long-press or a detail screen on mobile. An ellipsis with no escape is data deleted, not data folded.
- **Never a bare clip.** A hard cut with no marker tells the reader nothing was removed, so a truncated value reads as the whole one. The three dots exist to say *there is more*.

The mechanics that make the default actually fire differ by framework — Flutter's in [`flutter.md`](flutter.md), CSS's in [`react.md`](react.md). The wireframe that tests this before a line is written is the overflow frame in [`docs/workflow/previews.md`](../workflow/previews.md).

## Lists

- **Hanging-indent wrapped list lines.** A dash or numbered list item that wraps in a narrow terminal reads as a fresh bullet unless the continuation line is indented under the marker (2 spaces for `-`, matching the marker's width for a numbered list). Apply this to every list rendered narrow — plan output, gate blocks, findings, prose — not just code.
- **Split a compound bullet into nested facets.** When a single bullet is really two or more clauses stitched together with "and" or commas, break it into a one-line parent plus short nested items instead of one long wrapped line. Reserve this for bullets that are genuinely compound; a plain one-line bullet gains nothing from being forced into a nested shape.