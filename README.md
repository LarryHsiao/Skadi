# Skadi

<img src="assets/icon.svg" alt="Skadi icon — a pen nib" width="48" height="48">

My personal configuration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
and [Codex](https://learn.chatgpt.com/docs/codex). Global instructions, skills,
hooks, safety policy, and workflow state are version-controlled here and
installed into paired `~/.claude*` and `~/.codex*` homes by `install.sh`.

This page covers installing and using it. How the pieces work — the work
loop, the ticket→PR machine, every skill and hook — is told in the
[handbook](#the-handbook).

## Setup

```bash
git clone git@github.com:LarryHsiao/Skadi.git ~/skadi
cd ~/skadi
./install.sh --all           # install every registered pair
./install.sh ~/.claude-work  # backward-compatible Claude-only install
./install.sh --codex ~/.codex-work
./install.sh --pair ~/.claude-work ~/.codex-work
```

A machine with no registry is registered with **one** pair — `~/.claude` and
`~/.codex`. Extra profiles are never taken by default; `--pair` adds one, and
`--all` then keeps every registered row in step. Pair mappings live in
`~/.skadi/install/roots.tsv`. Re-running is safe: Codex authentication,
sessions, `config.toml`, unrelated rules/hooks/skills, and user text outside
Skadi's marked `AGENTS.md` block are preserved. After installing a Codex home,
start a new session and use `/hooks` once to review and trust the new or
changed lifecycle hooks.

**This repo is the source of truth.** `~/.claude*/` and Skadi-owned files
under `~/.codex*/` are installed copies. Make changes here first, then
propagate with `/install` (inside a session) — it walks every registered pair,
where a bare `./install.sh` syncs only the default one. Codex homes receive
the same skill tree rendered into Codex's strict frontmatter, `$skill`
invocations, and hook paths. Paired homes share Skadi routing and preferences
under `~/.skadi/profiles/`, but never authentication or chat history.

### Launching a profile

Neither tool reads the registry at launch — each is pointed at a home by an
environment variable, so an unqualified `claude` or `codex` always speaks for
the default one:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
CODEX_HOME="$HOME/.codex-work" codex
```

Bind each to a word in `~/.zshrc` (or `~/.bashrc`) rather than retyping it:

```bash
alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'
alias codex-work='CODEX_HOME="$HOME/.codex-work" codex'
```

## Using it

Skills are slash commands — `/name` in Claude, `$name` in Codex — and the
same installed workflow answers to both. Three things happen without being
asked:

- **Every free-form change opens with a gate** — a size gauge, acceptance
  outcomes, non-goals, and a change summary — and waits for your word before
  the first edit. Slash-invoked skills run straight through; read-only turns
  are exempt. "Just do it" stands the gate down for the session.
- **Every completed task closes with a review and a fresh verification** —
  a read-only agent checks the diff against what was asked, findings are
  mended, and the tests run again in the same turn before "done" is spoken.
- **The statusline** under every turn shows project, diff, model, quota,
  standing windows, and sky. Codex uses its native `/statusline` picker
  instead.

The turn-by-turn ritual is chapter I of the handbook; the ticket→PR machine
(`/council` → `/celebrimbor` → `/mithrandir` and their sweeps) is chapter II;
the skills catalogue is chapter III.

### The handbook

A browsable HTML field guide — `./handbook.sh` opens it, served by the
situation board (`/board`).

| Chapter | What it tells |
|---|---|
| I. [The Work Loop](handbook/work-loop.html) | From a task's weighing to the word "done" — gate, previews, implementation loop, compliance review, fresh verification |
| II. [Plan · Forge · Review](handbook/plan-forge-review.html) | How a ticket becomes a merged change — the council→forge→review machine, the comment grammar that threads it, the skeleton-stage arc |
| III. Skills Cheatsheet | Every skill, one card each, generated from the `SKILL.md` files on each `/board refresh`; served by Henneth |
| IV. [The Rúmil Road](handbook/rumil-flow.html) | How a product spec becomes an engineering plan |
| V. [The Untracked Road](handbook/untracked-road.html) | The same arc as II, with no issue tracker at its centre |
| VI. [The Fellowship of Skills](handbook/skill-fellowship.html) | One map of every skill by the stage of work it serves |
| VII. [The Standing Machinery](handbook/standing-machinery.html) | What outlives a turn — windows, daemons, the external runner, the profile registry |
| VIII. [The Instruments](handbook/instruments.html) | The statusline row by row, the `/este` and `/fidelity` scorecards, the session's habits |
| IX. [The Hooks](handbook/hooks.html) | Every script under `hooks/`, grouped by what it serves |

## What's Inside

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global instructions loaded into every conversation |
| `AGENTS.md` | Runtime-neutral global instructions installed into Codex homes |
| `assets/` | The repo icon — a pen nib, embedded above |
| `TODO.md` | The one item still open across the repo, kept so a successor session knows where to look |
| `settings.json` | Model, permissions, plugins, and hook definitions |
| `codex/hooks.json` | Native Codex lifecycle-hook definitions |
| `codex/rules/skadi.rules` | Native Codex command escalation policy |
| `statusline.sh` | The terminal status line — eight rows of project, diff, model, quota, standing windows, and sky. See handbook chapter VIII |
| `hooks/` | Shell scripts that run before/after tool calls, or serve as a skill's hands. See handbook chapter IX |
| `hooks/lint.sh` | Shellcheck gate over the scripts a branch changed — `./hooks/lint.sh` (add paths to widen it) |
| `skills/` | Custom slash-command skills. See handbook chapters III and VI |
| `docs/` | Style guides, tool guides, and workflow notes referenced from `CLAUDE.md` via `@docs/...` |
| `output-styles/` | Output style definitions, copied into `~/.claude/output-styles/`; `tolkien-narrator` is the default `outputStyle` in `settings.json` |
| `previews/henneth/skadi-theme.css` | Shared parchment stylesheet copied beside the Henneth preview artifacts |
| `install.sh` | Copy installer (idempotent, safe to re-run) |
| `handbook/` | The HTML handbook — the cover plus the nine chapters above |
| `handbook.sh` | Open the handbook, served by the situation board — `./handbook.sh` |
| `tests/` | Python tests for the Jira hooks and the skeleton-rung deriver; the rest ride beside their hooks as `*.test.sh` / `test_*.py` |
| `CLAUDE.stub.md` | The one-line marker left in `~/.claude/` pointing at whichever profile root holds the live config |

## Machine-local state

`~/.skadi/` holds runtime state that `install.sh` does not create and git does
not track — sweep cursors, the handoff mailbox, per-project routing. Most of it
regenerates on demand and costs nothing to lose.

One file does not. **`~/.skadi/tone-external.md`** sets the register for every
PR/MR and tracker comment and description Skadi writes; the *External posts*
rule in `output-styles/tolkien-narrator.md` reads it. Its presence changes that
default, its absence means plain human tone. It is written by hand, no install
run recreates it, and nothing versions it — a lost disk takes it with it, so
keep a copy somewhere private.

It is kept out of this repo **deliberately**: it describes a personal
communication register, and this repo is public. Do not "fix" the gap by
committing it.

**`~/.skadi/profiles/<profile>/subagent-runner.md`** names the CLI a session
in that profile hands delegated work to instead of spawning an Agent-tool
subagent (`codex exec`, say, in a work profile with spare Codex quota), or
`none`. Per profile on purpose: a machine may hold `codex` and still want it
only for work. `install.sh` never writes it — it prints a hint per unset
profile — and the first session there that wants a subagent asks once.
`SKADI_PROFILE=<profile> hooks/subagent-runner.sh init` seeds it from a
runner found on `PATH`, `init --none` records the refusal, `show` prints it.

### Mechanism cache (Pengolodh)

`~/.skadi/mechanisms/<repo-key>/index.md` — one small file per repo, created
on first use by `hooks/pengolodh.sh`. Nothing here needs setup to work:

| What | Default | Optional upgrade |
|---|---|---|
| Storage root | `~/.skadi/mechanisms/` | Override with `PENGOLODH_DIR` |
| Version control | None — plain files on one machine | `git -C ~/.skadi/mechanisms/ init` (offered by `/pengolodh status` when absent) |
| Cross-machine sync | Off, even with git present | `touch ~/.skadi/mechanisms/.autosync` (offered by `status` once git exists) |

Git and `.autosync` are two separate switches on purpose — see
`docs/workflow/mechanism-cache.md` for why commit is automatic once git
exists but pull/push are not, and why a diverged sync stops rather than
auto-merging. Skipping both entirely costs nothing but cross-machine
accumulation; the cache still injects into every session on the machine
that wrote it.

## License

MIT
