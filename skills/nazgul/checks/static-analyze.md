---
name: Static analysis configured
scope: [diff, project]
---

A foundation project pins a lint configuration so style and obvious errors are checked uniformly. A bare or empty config does not count — the configuration must pull in a recommended ruleset (e.g. `package:flutter_lints/flutter.yaml`, `package:lints/recommended.yaml`, `package:very_good_analysis/...`) or declare an explicit ruleset of equivalent strength.

Scan the given target — whether the supplied diff or the standing project tree — for the lint configuration. The shape varies by language:

- Flutter / Dart: `analysis_options.yaml` with an `include:` of a recommended ruleset, or an explicit `linter.rules:` section listing project-defined rules.
- TypeScript / JavaScript: `eslint.config.{js,ts,mjs,cjs}`, `.eslintrc.*`, or `biome.json` extending a recommended preset (e.g. `eslint:recommended`, `@typescript-eslint/recommended`, `biome/recommended`).
- Go: `.golangci.yml` / `.golangci.yaml` enabling at least the default linters, or a CI step invoking `go vet`, `staticcheck`, or `golangci-lint`.
- Rust: `clippy.toml`, or a `[lints]` table in `Cargo.toml` enabling at least `clippy::all` or a category.
- Python: `ruff.toml`, or a `[tool.ruff]` section in `pyproject.toml`, selecting at least one ruleset (e.g. `select = ["E", "F"]`).
- Swift: `.swiftlint.yml` with rules enabled (default if not opted out).
- Kotlin: `detekt.yml` / `.detekt.yml` with the default ruleset on.

**When the target is a diff** — flag changes that weaken or remove the configuration:

- Pass when no relevant config file is touched, or the change strengthens or preserves the ruleset (e.g. adds rules, swaps in a stricter preset).
- Fail when the diff deletes the config file, removes an `include:` of a recommended ruleset, drops a `linter.rules:` block, or swaps a recommended preset for a weaker one.

**When the target is a project root** — survey the standing tree:

- Pass when a config file exists and pulls in a recommended ruleset, or declares an explicit ruleset of its own.
- Fail when no config file is found in the recognised shape for the project's primary language; or the config exists but is empty / trivially permissive (e.g. `analysis_options.yaml` with only an empty `include:` line and no `linter.rules:` block).

n/a when:
- The project contains no source code in any recognised language (documentation- or asset-only repository).

On fail, name what was searched and the nearest miss (e.g. "analysis_options.yaml present but missing `include:` of a recommended ruleset and no `linter.rules:` declared").
