# Flutter Style Guide

## Tooling

- Always use `fvm flutter` instead of `flutter` for any Flutter command.

## Dependencies

- When the user asks to "update" a dependency that is pinned to a source reference (git branch, tag, commit, or path) rather than a semver version, the version string won't change — the underlying ref will. Run `dart pub upgrade <package>` (prefix with `fvm` if the project uses FVM) so pub fetches the latest commit on that ref instead of reusing the cached one. Example: a library the project references via `master` adds a new commit — `pub get` alone will keep the cached commit; `pub upgrade <package>` pulls the new one.
