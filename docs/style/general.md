# Code Style Guide

> Language- or framework-specific rules belong in their own style file, not here.

## Naming

- **No `-er` suffix** for classes or packages (no `Manager`, `Helper`, `Handler`, `Processor`, etc.). Name things after the domain concept they represent.
- **Classes and objects are nouns.** If you can't name it without a verb, it's probably a method, not a class.
- **Methods are verbs.** They do things.

## Methods

- Keep methods under 25 lines. If it grows beyond that, extract smaller private methods.

## General-purpose code

- When editing a file meant to be a general-purpose widget (a shared component, a utility, a base class), do not add domain-specific logic. Keep it general. If the change needs domain knowledge, lift it to the caller — leave the widget unaware.

## Indexing

- **Guard every index access against an empty container.** Before `xs[0]`, `xs.first`, `xs.last`, or `xs[i]`, check the length or use a safe accessor (`xs.firstOrNull`, `xs.elementAtOrNull(i)`, pattern destructuring with a fallback). The empty list is the common pitfall — `xs[0]` on `[]` raises, not returns null. The same care applies to map lookups, regex match groups, and argument arrays.