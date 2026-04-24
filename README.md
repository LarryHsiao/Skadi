# Skadi

My personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration. Global instructions, settings, custom skills, and hooks — all version-controlled and copied into `~/.claude/` (and any other configured roots) by `install.sh`.

## What's Inside

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global instructions loaded into every conversation |
| `settings.json` | Model, permissions, plugins, and hook definitions |
| `statusline.sh` | Custom status line script |
| `hooks/` | Shell scripts that run before/after tool calls |
| `skills/` | Custom slash-command skills |
| `install.sh` | Copy installer (idempotent, safe to re-run) |

### Features

- **Grammar check** — Every user message is silently checked for grammar and phrasing. If anything's off, a single corrected line is appended to the response with the changed tokens bolded on both sides (e.g. `"should **i** go?"` → `"should **I** go?"`). A counter hook tallies corrections per session so trends stay visible.
- **Tolkien narrator tone** — Measured cadence, a touch formal, a storyteller's weight. Tight sentences; no breathless filler, no hype.
- **Task sizing** — Every free-form action is weighed on the craftsman's triad (reach, depth, reversibility) and rendered as a three-tier gauge before a line is written. Medium and heavy tasks come with a best-effort breakdown into minimum-sized steps.
- **Change approval** — Slash-invoked skills run straight through; free-form edits pause for a brief summary and the user's word before touching the tree.
- **Multi-root install** — `/install` copies this repo into every root listed in memory (`~/.claude`, `~/.claude-personal`, `~/.claude-work`) so switching contexts stays consistent.
- **Source of truth** — `~/.claude/` is a copy. Edits there get overwritten on the next install; every change must land in this repo first.

### Skills

- `/install` — Copy this repo into every configured Claude config root
- `/commit` — Generate a commit message from the diff and commit after approval
- `/commit-push` — Same as commit, then push to remote
- `/stage` — Interactively stage files
- `/summary` — Summarize staged changes
- `/reset` — Reset workspace to HEAD
- `/branch` — Switch to a target branch, safely handling uncommitted work
- `/prs` — Show open GitHub PRs requiring attention
- `/mrs` — Show open GitLab merge requests requiring attention
- `/jira` — Create or check status of Jira tickets
- `/daily` — Show Jira tasks grouped by status, sorted by priority
- `/working` — Start working on a Jira ticket
- `/eod` — End-of-day scan of configured repos for uncommitted/unpushed work
- `/focus` — Pomodoro focus timer
- `/preflight` — Run periodic maintenance checks and sync overdue items into the todo list
- `/nazgul` — Dispatch the Nine: one agent per check file, aggregating pass/fail verdicts into a single table
- `/council` — Convene a planning council on a tracker ticket: Erestor drafts, Elrond decides, all by comment
- `/cleanup-dev` — Free disk space by clearing dev caches and build artifacts
- `/publish` — Build Flutter release archives and collect into `build/publish/`
- `/publish-macos` — Bump version, build, and publish a macOS Xcode project to GitHub Releases or the Mac App Store

### Hooks

- **dir-guard** — Block Bash commands that run outside the project directory
- **pre-commit-guard** — Prevent unauthorized commits
- **destructive-warn** — Warn on destructive shell commands
- **flutter-analyze** — Run `flutter analyze` after editing Dart files
- **prettier-format** — Run Prettier after editing supported files
- **eslint-check** — Run ESLint after editing JS/TS files
- **grammar-reminder** — Inject the grammar-check reminder on every user prompt
- **grammar-counter** — Count grammar corrections at session stop
- **preflight-check** — Emit the preflight checklist state consumed by `/preflight`
- **jira-daily**, **prs-check**, **mrs-check**, **eod-git-check** — Data collectors for the matching skills
- **cleanup-dev-*** — Analyze, report, execute, and mark-run helpers for `/cleanup-dev`
- **council-youtrack-fetch**, **council-youtrack-comment** — YouTrack I/O for `/council`
- **publish-macos-target** — Remember whether a macOS project publishes to GitHub Releases or the Mac App Store

## Setup

```bash
git clone git@github.com:LarryHsiao/Skadi.git ~/skadi
cd ~/skadi
./install.sh                 # installs into ~/.claude by default
./install.sh ~/.claude-work  # or any other root
```

The installer copies every file into the target root. Re-running is safe — unchanged files are skipped. Inside a Claude session, `/install` iterates over all roots saved in memory in a single call.

## License

MIT
