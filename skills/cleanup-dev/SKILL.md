---
name: cleanup-dev
description: Free disk space by clearing dev caches and build artifacts. Reports sizes per bucket, asks per-bucket confirmation, then deletes only what the user approves. For fvm SDKs and per-project artifacts, user picks interactively. Use /cleanup-dev.
user_invocable: true
---

# Cleanup Dev Caches

Frees disk space by clearing common dev caches and build artifacts. Nothing is deleted without per-bucket approval.

## Workflow

### 1. Report global buckets

```bash
~/.claude/hooks/cleanup-dev-report.sh
```

Output is pipe-delimited `bucket|size|detail`. Present as a table sorted by size descending. Skip buckets whose size is `-` (missing) or `0B`.

### 2. Confirm per bucket

For each reportable bucket **except `fvm-versions`**, use AskUserQuestion:

```
question: "Clean <bucket> (<size>)?"
options:
  - label: "Clean"
    description: "<what it does>"
  - label: "Skip"
    description: "Leave it alone"
```

Collect the approved buckets into a list.

### 3. Execute approved buckets

Run once with all approved bucket keys:

```bash
~/.claude/hooks/cleanup-dev-execute.sh <bucket1> <bucket2> ...
```

Skip this step if the list is empty.

### 4. fvm versions (interactive)

If `fvm-versions` count > 1, list the installed versions:

```bash
fvm list
```

Parse the version strings. Use AskUserQuestion with one option per version (multi-select) plus a "Skip all" option. For each selected version:

```bash
~/.claude/hooks/cleanup-dev-execute.sh fvm-remove <version>
```

Never auto-remove — always ask.

### 5. Per-project build artifacts (interactive)

Ask whether to scan for per-project artifacts (`node_modules`, `.dart_tool`, `build`, `target`, `.next`). If approved:

```bash
~/.claude/hooks/cleanup-dev-project-scan.sh
```

Output is `size|path`, already sorted by size desc. Present the top entries. Use AskUserQuestion (multi-select) to let the user pick which paths to delete. For each approved path:

```bash
~/.claude/hooks/cleanup-dev-execute.sh project-path <path>
```

The execute script refuses any path whose basename isn't one of the allowed artifact names — safety net.

### 6. Summary

Report what was cleaned and roughly how much space was freed (subtract pre-report total from a fresh report of the same buckets if you want an exact number — otherwise just list the cleaned buckets).

## Buckets

**Auto-reported (per-bucket approval):**
- `xcode-derived-data` — `~/Library/Developer/Xcode/DerivedData`
- `xcode-archives` — `~/Library/Developer/Xcode/Archives`
- `xcode-sim-unavailable` — `xcrun simctl delete unavailable`
- `gradle-caches` — `~/.gradle/caches`
- `gradle-daemon` — `~/.gradle/daemon`
- `pub-cache` — `~/.pub-cache` (re-downloaded on next `pub get`)
- `homebrew-cache` — `brew cleanup -s`
- `npm-cache`, `pnpm-store`, `yarn-cache`
- `cargo-registry`, `cargo-git`
- `jetbrains-caches`, `jetbrains-logs`
- `android-studio-caches`
- `docker-prune` — `docker system prune -af` + `docker volume prune -f`

**Interactive (user picks individual items):**
- `fvm-versions` — Flutter SDK versions via fvm
- `project-artifacts` — per-project `node_modules`, `.dart_tool`, `build`, `target`, `.next`

## Safety

- Scripts refuse unknown buckets and refuse arbitrary paths (only recognized artifact dir names).
- No `sudo`, no system paths, no `~/Library` outside cache/log dirs.
- Report scripts are read-only; only `cleanup-dev-execute.sh` deletes.
