# Dart Style Guide

## Naming

- **No `-er` suffix** for classes or packages (no `Manager`, `Helper`, `Handler`, `Processor`, etc.). Name things after the domain concept they represent.
- **Classes and objects are nouns.** If you can't name it without a verb, it's probably a method, not a class.
- **Methods are verbs.** They do things.

## Methods

- Keep methods under 25 lines. If it grows beyond that, extract smaller private methods.
