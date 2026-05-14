# Flutter Style Guide

## Tooling

- Always use `fvm` for the Flutter SDK. Run commands as `fvm flutter <cmd>` so they target the project's pinned SDK version.

## Dependencies

- When the user asks to "update" a dependency that is pinned to a source reference (git branch, tag, commit, or path) rather than a semver version, the version string won't change — the underlying ref will. Run `dart pub upgrade <package>` (prefix with `fvm` if the project uses FVM) so pub fetches the latest commit on that ref instead of reusing the cached one. Example: a library the project references via `master` adds a new commit — `pub get` alone will keep the cached commit; `pub upgrade <package>` pulls the new one.

## Code Generation

- When editing a class marked `@freezed` — or any class whose companion files come from `build_runner` (`.freezed.dart`, `.g.dart`, `.gr.dart`, and the like) — never hand-edit the generated file or have the assistant rewrite it. Run the build itself: `fvm dart run build_runner build --delete-conflicting-outputs` (or `watch` during active work). The generator's output is the source of truth; an AI-stitched substitute drifts in shape — copyWith signatures, `fromJson` dispatch, union helpers — and the next legitimate build overwrites it, silently undoing the patch.
