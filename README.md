# Skadi

My personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration. Global instructions, settings, custom skills, and hooks — all version-controlled and symlinked into `~/.claude/`.

## What's Inside

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global instructions loaded into every conversation |
| `settings.json` | Model, permissions, plugins, and hook definitions |
| `statusline.sh` | Custom status line script |
| `hooks/` | Shell scripts that run before/after tool calls |
| `skills/` | Custom slash-command skills |
| `install.sh` | Symlink installer (idempotent, safe to re-run) |

### Skills

- `/commit` — Generate a commit message from the diff and commit after approval
- `/commit-push` — Same as commit, then push to remote
- `/focus` — Pomodoro focus timer
- `/reset` — Reset workspace to HEAD
- `/stage` — Interactively stage files
- `/summary` — Summarize staged changes
- `/working` — Start working on a Jira ticket

### Hooks

- **dir-guard** — Block Bash commands that run outside the project directory
- **pre-commit-guard** — Prevent unauthorized commits
- **destructive-warn** — Warn on destructive shell commands
- **flutter-analyze** — Run `flutter analyze` after editing Dart files
- **prettier-format** — Run Prettier after editing supported files
- **eslint-check** — Run ESLint after editing JS/TS files

## Setup

```bash
git clone git@github.com:LarryHsiao/Skadi.git
cd Skadi
./install.sh
```

The installer symlinks everything into `~/.claude/`. Existing files are backed up with a timestamp suffix before being replaced.

## License

MIT
