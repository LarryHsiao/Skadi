---
name: No hardcoded user paths
scope: [diff, project]
---

Hardcoded user paths — `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` — travel poorly. They work on the author's machine and break everywhere else. Configuration belongs in env vars, args, or a project-relative path.

Scan the given target — whether the supplied diff or the standing project tree — for committed user paths.

Patterns to flag:

- `/Users/<name>/` — macOS home directory paths.
- `/home/<name>/` — Linux home directory paths.
- `C:\Users\<name>\` or `C:/Users/<name>/` — Windows home paths.
- Other absolute paths under home-like roots (`/private/var/folders/...`, `/Users/Shared/...`).

Pass when:
- No such path appears in first-party source / configuration.
- A match appears only in:
  - Comments or documentation as an explicit example.
  - Test fixtures clearly marked as machine-specific.
  - Configuration files that explicitly support local overrides (`.local.env`, `*.local.json`, `*.local.yaml`).

Fail when:
- A line of source, config, or shell hard-codes a user-specific path. For diff scope, the offending line is in the diff additions; for project scope, it is anywhere in first-party source.

Do not flag:
- Lock files, build artefacts, or IDE settings checked into the repo (`pubspec.lock`, `package-lock.json`, `Cargo.lock`, `Podfile.lock`, `.idea/`, `*.xcworkspace/`, `*.xcodeproj/`) — paths there are mechanical, not authored.
- System paths that are genuinely portable in their context (`/tmp/`, `/var/log/`, `/etc/`) when used in tooling that targets that system.
- References to environment variables that *expand to* a home path (`$HOME/.config`, `${USERPROFILE}\AppData`, `$env:USERPROFILE`).
- Documentation that describes layout in tilde form (`~/.skadi/handoff/<channel>.json` is fine; `/Users/larryhsiao/.skadi/...` is not).
- Generated source under conventional roots (`*.g.dart`, `*_pb.go`, `__generated__/`, `node_modules/`, `vendor/`).

On fail, name each occurrence as `file:line` and quote the offending path prefix. For project scope with many findings, list up to five and append "and N more".
