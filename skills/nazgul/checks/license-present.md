---
name: License present
scope: project
---

A foundation project carries an explicit licence so users and contributors know the terms of use. Without one, the work is "all rights reserved" by default — usually the opposite of intent.

Scan the project root for a licence file or manifest declaration:

- `LICENSE`, `LICENSE.md`, `LICENSE.txt`, with case variants (`LICENCE`, `License`).
- `COPYING` or `COPYING.md` — common for GPL-licensed projects.
- A `license:` field in `pubspec.yaml` (Dart) — non-empty.
- A `"license":` field in `package.json` (JS / TS) — non-empty and not the literal string `"UNLICENSED"`.
- A `license = "..."` field in `Cargo.toml` (Rust) — non-empty.

Pass when:
- A licence file exists at the project root and is non-empty.
- OR the project's package manifest declares a non-empty licence value.

Fail when:
- No licence file is found and no manifest declares one.
- A licence file exists but is empty or contains only a placeholder (e.g. "TODO: add licence").

n/a when:
- The project is explicitly marked as private/internal in its manifest (`"private": true` in `package.json`, `publish_to: 'none'` in `pubspec.yaml`) and no public usage is implied.

On fail, name what was searched.
