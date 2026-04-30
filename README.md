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
| `docs/` | Style guides referenced from `CLAUDE.md` via `@docs/...` |
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
- `/commit` — Generate a commit message from the diff and commit after approval; pass `--push` to push after the commit lands
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
- `/nazgul` — Dispatch the Nine: one agent per check file, aggregating pass/fail verdicts into a single table. Default scope is the diff (uncommitted, branch, or sha range); `/nazgul project` rides over the standing project tree instead. Each check declares its scope via frontmatter
- `/council` — Convene a planning council on a tracker ticket: Erestor drafts, Elrond decides, all by comment
- `/glorfindel` — Sweep every open ticket in a project and run the council on each, aggregating one report
- `/celebrimbor` — Forge an approved counsel into a PR/MR: branch off base, dispatch the smith, open the PR/MR, post `[GWAITH]` on the ticket
- `/lindir` — Read a PR/MR and render a five-section review brief; with the `approve` verb, ask once and submit an approving review on the forge
- `/mithrandir` — Read a PR/MR and render a four-axis verdict (cohesion, proportion, direction, risk) with a tier (sound/wavering/off) and short reasoning; with the `comment` verb, ask once and post the verdict to the forge. Tone defaults to lore for chat and plain for forge; `--plain` / `--lore` flags override
- `/scribe` — Export a Minerva planning section to YouTrack, Outline, or disk; carries title, scope, Figma screenshot, sub-tasks, and open questions, and updates in place via inline markers
- `/cleanup-dev` — Free disk space by clearing dev caches and build artifacts
- `/vocab` — Personal vocabulary deck: look up a word in EN + ZH-TW, store as a card under `~/.skadi/vocab/`, surface due cards via spaced repetition
- `/publish` — Build Flutter release archives and collect into `build/publish/`
- `/publish-macos` — Bump version, build, and publish a macOS Xcode project to GitHub Releases or the Mac App Store

### Hooks

- **dir-guard** — Block Bash commands that run outside the project directory
- **pre-commit-guard** — Prevent unauthorized commits
- **destructive-warn** — Warn on destructive shell commands
- **secret** — Resolve a credential field for a service from Vaultwarden via `bw serve`, falling back to an env var
- **flutter-analyze** — Run `flutter analyze` after editing Dart files
- **prettier-format** — Run Prettier after editing supported files
- **eslint-check** — Run ESLint after editing JS/TS files
- **grammar-reminder** — Inject the grammar-check reminder on every user prompt
- **session-readme** — On `SessionStart`, inject the project's `README.md` (if any) as additional context
- **grammar-counter** — Count grammar corrections at session stop
- **preflight-check** — Emit the preflight checklist state consumed by `/preflight`
- **jira-daily**, **prs-check**, **mrs-check**, **eod-git-check** — Data collectors for the matching skills
- **cleanup-dev-*** — Analyze, report, execute, and mark-run helpers for `/cleanup-dev`
- **council-youtrack-fetch**, **council-youtrack-comment**, **council-jira-fetch**, **council-jira-comment** — Tracker I/O for `/council` (YouTrack and Jira)
- **glorfindel-youtrack-list**, **glorfindel-jira-list** — List open tickets matching a filter for `/glorfindel`
- **celebrimbor-github-pr**, **celebrimbor-gitlab-mr** — Push a branch and open a PR/MR on GitHub or GitLab via `gh`/`glab`; body taken from stdin
- **lindir-github-pr**, **lindir-gitlab-mr** — Read a PR/MR via `gh`/`glab` and emit a JSON brief for `/lindir`
- **lindir-github-approve**, **lindir-gitlab-approve** — Submit an approving review on a PR/MR via `gh`/`glab` for `/lindir approve`
- **mithrandir-github-comment**, **mithrandir-gitlab-comment** — Post a comment on a PR/MR via `gh`/`glab` for `/mithrandir comment`; body taken from stdin
- **youtrack-state**, **jira-state** — Idempotent state transitions on YouTrack and Jira tickets, used by `/glorfindel` (on `[FORTH]`) and `/celebrimbor` (after `[GWAITH]`)
- **publish-macos-target** — Remember whether a macOS project publishes to GitHub Releases or the Mac App Store
- **vocab-cards** — Emit every vocab card with SRS state and days-until-due as TSV for `/vocab review` and `/vocab list`
- **nazgul-checks-mark-reviewed** — Stamp the rubric-review state file consumed by `/preflight`; called by `/nazgul reviewed`

## Council → Forge

`/council`, `/glorfindel`, and `/celebrimbor` work as one machine for turning a ticket into a PR/MR — the ticket thread is the record, no side channels.

1. **Plan** — `/council TICKET-ID`. Erestor (subagent) reads the ticket and drafts `[COUNSEL vN]` as a comment. Elrond (the human) replies in prose; each `/council TICKET-ID` turns the wheel another round, weaving Elrond's reply into `[COUNSEL v(N+1)]`. Read-only — never writes code or opens PRs.
2. **Sweep** — `/glorfindel TRACKER PROJECT --filter <filter>`. Visits every ticket the filter returns and runs the council on each. Loop-safe — quiet on threads with no fresh counsel since the bot last spoke. A ticket only enrolls in the sweep once it carries either an existing `[COUNSEL v…]` or a `[MELLON]` summons from Elrond, so a fresh project is not flooded with v1 drafts on the first ride.
3. **Forge** — `/celebrimbor TRACKER PROJECT [--filter <filter>] [--ticket <id>]`. Picks one ticket bearing `[FORTH]` without `[GWAITH]`, branches off the project's base, dispatches the smith subagent to implement the approved counsel, opens a draft PR/MR via the forge hook, and posts `[GWAITH] <url>` back on the ticket. Single-shot — one ticket per invocation; `/loop` covers throughput.

### Comment grammar

Seven tokens carry state. Everything else is counsel. Matching is case-insensitive; English aliases are recognized everywhere their Tolkien primaries are.

| Token | Alias | Author | Meaning |
|---|---|---|---|
| `[COUNSEL vN]` | `[PLAN vN]` | Erestor | Draft of the plan; N increments each round |
| `[PARLEY]` | `[AGENT-ASK]` | Erestor | A single clarifying question — speech between sides to come to terms |
| `[MELLON]` | `[FRIEND]` | Elrond | Summons — *speak, friend, and enter*; enrolls a ticket in `/glorfindel` sweeps |
| `[FORTH]` | `[APPROVE]` | Elrond | The plan stands; council adjourns with approval |
| `[NAY]` | `[REJECT]` | Elrond | The plan is abandoned; council adjourns without approval |
| `[NAMARIE]` | `[FAREWELL]` | Elrond | *Farewell* — adjourn without verdict (out-of-band resolution, ticket subsumed, etc.) |
| `[GWAITH]` | `[FORGED]`, `[SHIPPED]` | Celebrimbor | The deed is wrought; PR/MR opened on the approved counsel; body carries the URL |

### When the council adjourns

Adjournment puts a ticket at rest. `/glorfindel` records its action and stops drafting on the thread; further sweeps over the same ticket are silent. Each verdict shapes what comes next:

- `[FORTH]` — the plan stands. The ticket is now eligible for `/celebrimbor`. Once `[GWAITH]` appears, the forge will not pick it up again.
- `[NAY]` — the plan is abandoned. `/celebrimbor` ignores the ticket; if a new plan is wanted, redraft via `/council`.
- `[NAMARIE]` — adjourn without verdict. Used when the thread closes for reasons other than approval or rejection (resolved out-of-band, ticket subsumed by another, deferred indefinitely).

Verdict precedence is *by token, not by chronology*: `[FORTH]` > `[NAY]` > `[NAMARIE]`. If Elrond posts `[NAY]` and later posts `[FORTH]`, the council adjourns approved. (Same if the order is reversed.) This makes it safe to overrule yourself in the same thread.

### Turn limit

The council brakes at five `[COUNSEL vN]`s without a verdict. On what would be `[COUNSEL v6]`, the comment hook posts a single canned `[PARLEY]` instead — *"The council has turned five times without a verdict. Take it offline."* — and stops. `[PARLEY]` posts do not count toward the limit; only `[COUNSEL vN]`s do. The signal is that the comment thread has outgrown the problem; either split the ticket or move to a doc / call.

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
