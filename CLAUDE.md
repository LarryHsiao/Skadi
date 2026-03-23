# Personal Claude Configuration

This repository tracks my personal Claude Code setup: global instructions, settings, skills, and hooks.

## About This Repo

- `CLAUDE.md` — this file, symlinked to `~/.claude/CLAUDE.md`
- `settings.json` — global Claude settings, symlinked to `~/.claude/settings.json`
- `skills/` — custom skills, each file symlinked into `~/.claude/skills/`
- `hooks/` — hook scripts referenced from settings
- `install.sh` — sets up all symlinks (idempotent, safe to re-run)
