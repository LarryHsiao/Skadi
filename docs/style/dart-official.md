# Effective Dart — Official Conventions

> Distilled from the official **Effective Dart** guide — four pages at
> `dart.dev/effective-dart/{style, documentation, usage, design}`. These are the language's own
> recommended conventions, not personal house style — so they apply to **every**
> Dart/Flutter project under review, regardless of repo owner or forge. Your
> hand-written rules in [`flutter.md`](flutter.md) and [`general.md`](general.md)
> stay gated to your own repos; this file does not.
>
> Vendored once, not fetched live — **last refreshed 2026-06-17**. When the upstream
> guide moves, re-distill this file from the four source pages above and update the date.

The directive verbs carry the official weight: **DO** / **DON'T** are firm,
**PREFER** / **AVOID** hold unless there's a good reason, **CONSIDER** is a nudge.

## Style — Identifiers

- **DO** name types, enums, typedefs, and extensions in `UpperCamelCase`.
- **DO** name packages, directories, and source files in `lowercase_with_underscores`.
- **DO** name import prefixes in `lowercase_with_underscores`.
- **DO** name other identifiers (members, variables, parameters) in `lowerCamelCase`.
- **PREFER** `lowerCamelCase` for constant names (not `SCREAMING_CAPS`).
- **DO** capitalize acronyms longer than two letters like words (`HttpRequest`, not `HTTPRequest`); two-letter ones stay all-caps (`ID`, `IO`).
- **DON'T** use a leading underscore for an identifier that isn't private.
- **DON'T** use prefix letters (`kConstant`, Hungarian notation).
- **DON'T** explicitly name libraries with a `library` directive.

## Style — Ordering

- **DO** place `dart:` imports before other imports.
- **DO** place `package:` imports before relative imports.
- **DO** put `export`s in their own section after all imports.
- **DO** sort each import/export section alphabetically.

## Style — Formatting

- **DO** format code with `dart format`.
- **CONSIDER** reshaping code to format more cleanly.
- **PREFER** lines of 80 characters or fewer.
- **DO** use curly braces for all flow-control statements (except a single-line `if` with no `else`).

## Documentation

- **DO** format comments like sentences — capitalize, end with a period.
- **DON'T** use block comments (`/* … */`) for documentation; use `///`.
- **DO** use `///` doc comments to document members and types.
- **PREFER** doc comments on public APIs; **CONSIDER** them on private APIs and a library-level comment.
- **DO** start a doc comment with a single-sentence summary, in its own paragraph.
- **AVOID** redundancy with the surrounding context (don't restate the obvious).
- **PREFER** third-person verbs for function/method comments describing a side effect ("Starts…", "Returns…").
- **PREFER** a noun phrase for non-boolean variable/property comments; **PREFER** "Whether …" for booleans.
- **DON'T** document both the getter and the setter of a property — document one.
- **DO** use square brackets `[identifier]` to refer to in-scope identifiers.
- **DO** use prose to explain parameters, return values, and exceptions.
- **DO** put the doc comment before any metadata annotations.
- **AVOID** excessive markdown and HTML; **PREFER** backtick fences for code.
- **PREFER** brevity; **AVOID** abbreviations and acronyms unless obvious.

## Usage — Libraries & imports

- **DON'T** import libraries from inside another package's `src` directory.
- **DON'T** let import paths reach into or out of `lib`.
- **PREFER** relative import paths within a package's own `lib`.
- **DO** use strings (not the legacy symbol form) in `part of` directives.

## Usage — Null

- **DON'T** explicitly initialize a variable to `null` (it's the default).
- **DON'T** give a parameter an explicit default of `null`.
- **AVOID** `late` when you need to check whether initialization happened.
- **CONSIDER** type promotion / null-check patterns over force-unwrapping nullable types.

## Usage — Strings & collections

- **DO** concatenate string literals with adjacent strings, not `+`.
- **PREFER** interpolation over concatenation; **AVOID** needless `{}` in interpolation.
- **DO** use collection literals (`[]`, `{}`, `<T>{}`) where possible.
- **DON'T** use `.length` to test emptiness — use `isEmpty` / `isNotEmpty`.
- **AVOID** `Iterable.forEach()` with a function literal — use a for-in loop.
- **DO** use `whereType<T>()` to filter by type; **AVOID** `cast()` where a nearby operation can carry the type.

## Usage — Functions, variables, members

- **DO** use a function declaration to bind a function to a name.
- **DON'T** create a lambda when a tear-off will do (`xs.map(parse)`, not `xs.map((x) => parse(x))`).
- **DO** follow one consistent rule for `var` vs `final` on locals.
- **AVOID** storing what you can cheaply recompute.
- **DON'T** wrap a field in a trivial getter/setter pair.
- **PREFER** a `final` field for a read-only property.
- **CONSIDER** `=>` for simple one-expression members.
- **DON'T** use `this.` except to redirect to a named constructor or to avoid shadowing.
- **DO** initialize fields at their declaration when possible.

## Usage — Constructors

- **DO** use initializing formals (`this.x`) where possible.
- **DON'T** use `late` when a constructor initializer list will do.
- **DO** use `;` rather than `{}` for an empty constructor body.
- **DON'T** use `new`; **DON'T** use `const` redundantly.

## Usage — Error handling & async

- **AVOID** `catch` clauses with no `on` type; **DON'T** silently discard such errors.
- **DO** throw only `Error` types for programmatic bugs; **DON'T** deliberately catch `Error`.
- **DO** use `rethrow` to re-throw a caught exception.
- **PREFER** `async`/`await` over raw futures; **DON'T** mark a function `async` with no effect.
- **CONSIDER** higher-order stream methods over manual subscription; **AVOID** using `Completer` directly.

## Design — Names

- **DO** use terms consistently; **AVOID** abbreviations.
- **PREFER** putting the most descriptive noun last; **CONSIDER** making the call read like a sentence.
- **PREFER** a noun phrase for non-boolean properties; a non-imperative verb phrase for booleans, named "positively".
- **PREFER** an imperative verb phrase for a function whose main purpose is a side effect; a noun phrase when its purpose is to return a value.
- **AVOID** starting a method name with `get`; **PREFER** `to___()` for a copy, `as___()` for a backed view.
- **AVOID** describing the parameters in the function's name.

## Design — Classes, members, types

- **AVOID** a one-member abstract class where a function will do; **AVOID** a class of only static members.
- **DO** use class modifiers (`final`, `interface`, `base`, `sealed`) to control extension/implementation.
- **PREFER** a pure `mixin` or pure `class` over a `mixin class`.
- **CONSIDER** a `const` constructor where the class supports it.
- **PREFER** `final` fields and top-level variables.
- **DO** use getters for property-like reads, setters for property-like writes; **DON'T** define a setter without a getter.
- **AVOID** runtime type tests to fake overloading; **AVOID** public `late final` fields without initializers.
- **AVOID** returning nullable `Future`/`Stream`/collection types; **AVOID** returning `this` for a fluent interface.
- **DO** annotate types on variables without initializers, on fields/top-level vars when not obvious, and on function return and parameter types.
- **DON'T** redundantly annotate where the type is inferred (initialized locals, inferred lambda params, initializing formals).
- **AVOID** `dynamic` unless deliberately disabling static checking.
- **DO** use `Future<void>` for an async member that yields no value; **AVOID** `FutureOr<T>` as a return type.

## Design — Parameters & equality

- **AVOID** positional boolean parameters — name them, or split the method.
- **AVOID** optional positional parameters a caller might want to skip past; **AVOID** a mandatory parameter with a magic "no argument" value.
- **DO** use inclusive-start, exclusive-end for range parameters.
- **DO** override `hashCode` whenever you override `==`, and obey the mathematical rules of equality.
- **AVOID** custom equality on mutable classes; **DON'T** make the `==` parameter nullable.
