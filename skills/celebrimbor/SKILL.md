---
name: celebrimbor
description: Use when the user runs /celebrimbor <tracker> <project> [--filter <id-or-jql>] [--ticket <id>] [--base <branch>] [--ready] [--dry-run] [--confirm]. Forges an approved counsel into code: branches off the project's base, dispatches the smith subagent to implement Erestor's Steps, opens a draft PR/MR via the forge hook, and posts [GWAITH] on the ticket. Single-shot — one ticket per invocation.
user_invocable: true
---

# Celebrimbor — The Forge

Celebrimbor was the master smith of Eregion, lord of the Gwaith-i-Mírdain, who turned the wisdom of others into the wonders of the world. So this skill: it takes a counsel that Erestor has drafted and Elrond has approved, and beats it into a pull request.

## Ethos

- **The counsel is the contract.** Celebrimbor implements what was approved, no more, no less. If the counsel is wrong, abort — do not improvise.
- **One ticket per invocation.** The blast radius is bounded; the user paces. `/loop` covers throughput.
- **The thread is still the record.** The PR URL goes back onto the ticket as `[GWAITH]`, so the council and the forge stay in step.

## Argument parsing

`/celebrimbor <tracker> <project> [--filter <filter>] [--ticket <id>] [--base <branch>] [--ready] [--dry-run] [--confirm]`

| Argument | Required | Meaning |
|---|---|---|
| `<tracker>` | yes | `youtrack` (alias `yt`) or `jira` |
| `<project>` | yes | Project shortName / key (e.g. `MET`, `PSG`) |
| `--filter <filter>` | no* | Tracker-aware extra scope (same semantics as `/glorfindel`) |
| `--ticket <id>` | no | Skip the sweep; forge this exact ticket if it qualifies |
| `--base <branch>` | no | Override the saved base branch for this run only |
| `--ready` | no | Open PR/MR as ready-for-review (default: draft) |
| `--dry-run` | no | Plan everything; never push, never open, never post |
| `--confirm` | no | Ask once before opening the PR/MR |

*If `--ticket` is set, `--filter` is ignored. Otherwise `--filter` follows the same resolution order as Glorfindel: explicit > `default_filters.md` > error.

## Routing memory (all parallel to /council, /glorfindel)

| Concern | Memory file | Key | Resolution if missing |
|---|---|---|---|
| Tracker | `tracker_routing.md` | project prefix | Existing council hybrid dispatch |
| Repo path | `repo_routing.md` | `<tracker>:<project>` | AskUserQuestion, save |
| Forge | `forge_routing.md` | `<tracker>:<project>` | AskUserQuestion (`github` / `gitlab`), save |
| Base branch | `base_branch.md` | repo path | AskUserQuestion (default options: `master`, `main`), save |
| State mapping | `state_mapping.md` | `<tracker>:<project>` | Lazy bootstrap on the `forged` key — see "State transition" below |

`forge_routing.md` shape:

```markdown
---
name: Forge Routing
description: Project key to forge (github | gitlab) for /celebrimbor.
type: reference
---

- youtrack:MET → github
- jira:PSG → gitlab
```

`base_branch.md` shape:

```markdown
---
name: Base Branch
description: Default base branch per repo for /celebrimbor PR/MR targets.
type: reference
---

- C:\Users\mikes\phantom\skadi → master
```

## Forge dispatch

| Forge | Hook |
|---|---|
| `github` | `~/.claude/hooks/celebrimbor-github-pr.sh` |
| `gitlab` | `~/.claude/hooks/celebrimbor-gitlab-mr.sh` |

Both hooks honour the same contract — `<branch> <base> <title> [--draft|--ready]` with body on stdin — and print the same success line: `opened: forge=<github|gitlab> url=<url> number=<n>`. The skill body is forge-blind below this line.

## State transition

After `[GWAITH]` is posted, look up the project's `forged` value in `state_mapping.md`. The file is shared with `/glorfindel`; format:

```
- youtrack:SKA → forth=To Do, forged=In Review
- jira:PSG     → forth=10006, forged=10007
```

YouTrack values are state names (the State field's value, e.g. `In Review`). Jira values are transition IDs (numeric, project-specific — see `GET /rest/api/3/issue/<key>/transitions`).

**Lazy bootstrap.** The first time `[GWAITH]` lands for a `<tracker>:<project>` whose row is absent or missing the `forged` key, ask via AskUserQuestion *once*:

- For YouTrack: prompt for the State name with an `(skip — never transition on GWAITH for this project)` option that seeds `forged=` (empty).
- For Jira: prompt for the transition ID with the same skip option, and remind the user how to find it.

Save and proceed. If the value is empty, skip the transition silently. If the hook errors, surface the error in the report (action stays `forged`); the PR/MR is open and `[GWAITH]` is posted regardless.

The state hook lives at `~/.claude/hooks/youtrack-state.sh` (YouTrack) or `~/.claude/hooks/jira-state.sh` (Jira); the tracker is the same one resolved in pre-flight step 1a.

## Workflow

### 1. Pre-flight resolution

In order:

a. **Tracker** — apply the council hybrid dispatch (see `skills/council/SKILL.md`, "Tracker routing") to bind `<fetch-hook>`, `<comment-hook>`, and `<list-hook>` to YouTrack or Jira.

b. **Repo path** — read `repo_routing.md` for `<tracker>:<project>`. If absent or `(no repo)`, stop with an error — Celebrimbor cannot forge without code.

c. **Forge** — read `forge_routing.md` for `<tracker>:<project>`. If absent, AskUserQuestion (options: `github`, `gitlab`) and save the answer. Resolve the matching forge hook.

d. **Base branch** — `--base` overrides everything. Otherwise read `base_branch.md` keyed by the resolved repo path. If absent, AskUserQuestion (options: `master`, `main`, plus "Other" affordance) and save.

e. **Working tree** — `cd` to the resolved repo path. Run `git status --porcelain`. If it returns any line, stop with an error: *"The working tree is not clean. Celebrimbor will not forge atop another's work."* Name the dirty paths.

f. **Forge auth sanity** — `gh auth status` (for github) or `glab auth status` (for gitlab). If either fails, surface the hook's auth-missing error and stop.

### 2. Build the qualifying-ticket set

If `--ticket <id>` is set, the candidate set is just that one ticket. Otherwise:

- Resolve `--filter` per Glorfindel's filter rules.
- Invoke `<list-hook> <project> [<filter>]` to get the open tickets.
- For each ticket in the list, fetch its thread via `<fetch-hook> <ticket-id>` and apply the **forge gate**:

**Forge gate.** A ticket qualifies iff *all* of:

1. The thread contains at least one `[COUNSEL vN]` (or alias `[PLAN vN]`) from the bot.
2. A verdict token `[FORTH]` (or alias `[APPROVE]`) appears in non-bot comments somewhere in the thread.
3. The thread does **not** contain `[GWAITH]` / `[FORGED]` / `[SHIPPED]` from the bot anywhere — already forged, leave it alone.

A ticket failing any of these three is silently dropped from the candidate set. (No `[FORTH]` means the council has not yet adjourned with approval; presence of `[GWAITH]` means the deed is already done.)

Report the gate's verdict for each ticket inspected so the user can see what was considered.

### 3. Select one ticket

- Zero qualify → tell the user *"No tickets bear approval awaiting the forge."* and stop.
- One qualifies → proceed with that one.
- Many qualify → AskUserQuestion with each candidate listed as `<TICKET-ID>: <one-line-summary> ([COUNSEL vN] approved <date>)`. The user picks one; the rest wait for the next invocation. No silent picking.

### 4. Verify the approved counsel

Re-read the selected ticket's thread. Locate the **latest** `[COUNSEL vN]` followed by an approved verdict. This is the contract Celebrimbor will implement.

Inspect its **Open questions** section. If any question has no follow-up answer from Elrond in subsequent comments, abort with a clear note: *"`[COUNSEL vN]` carries unresolved Open questions; Celebrimbor will not guess where the counsellor would not. Resolve and re-approve, or invoke `/council` to draft a new counsel that closes them."* Stop. Do not branch.

### 5. Branch

- Compute the branch name: `<TICKET-ID>-<slug>` where slug is the ticket summary, lowercased, ASCII-only, hyphen-separated, capped at ~40 chars. Example: `MET-3-add-session-summary-hook`.
- Check for existing remote branch: `git ls-remote --exit-code --heads origin <branch>`. If it exists, abort: *"Branch `<branch>` already exists on origin — refuse to overwrite."*
- `git fetch origin <base>` then `git checkout -B <branch> origin/<base>` (or `git checkout <base> && git pull && git checkout -b <branch>` — choose what is safe and idempotent on a clean tree).

### 6. Summon Celebrimbor (subagent)

Load the smith prompt from `<skill-dir>/celebrimbor.md`. Dispatch a subagent via the Agent tool, `subagent_type: general-purpose`, passing:

- The Celebrimbor prompt as the *system/instruction* portion.
- A tail block containing:
  - The ticket id, summary, description.
  - The full comment thread (chronological, with author labels).
  - The approved `[COUNSEL vN]` body, called out explicitly under a header like `## Approved counsel (your contract)`.
  - The repo root (resolved in step 1b).
  - The base branch.
  - The branch name.
  - The instruction: *"Implement the Steps of the approved counsel into the repo on the named branch. Commit your work. Do not push, do not open a PR/MR — the hook does that. Return either a `[FORGED]` block or an `[ABORT]` line per your prompt."*

The subagent returns either:

- `[FORGED]` block — extract `branch:`, `title:`, and the body (everything after the title line).
- `[ABORT] <reason>` — go to step 9 (cleanup) and stop with the reason.

Anything else: treat as drafting failure. Go to step 9, surface the malformed return.

### 7. Posting/creation gate

- `--dry-run`: print the parsed branch / title / body length. Skip steps 8 and the `[GWAITH]` post. Go to step 9 (cleanup: leave the branch local; do not delete since the user may want to inspect it). Tell the user: *"Dry run — branch `<branch>` exists locally with the smith's commits, no push, no PR, no comment."*
- `--confirm`: AskUserQuestion showing the branch, title, and the first ~10 lines of the body. On no, go to step 9 (cleanup with branch deletion). On yes, proceed.
- Otherwise: proceed.

### 8. Open the PR/MR and post `[GWAITH]`

a. **Open.** Pipe the body into the resolved forge hook:

```bash
printf '%s' "$BODY" | <forge-hook> <branch> <base> <title> <draft-flag>
```

`<draft-flag>` is `--draft` unless `--ready` was set. On success the hook prints `opened: forge=<f> url=<u> number=<n>`. On failure surface the JSON error and go to step 9 (cleanup with branch deletion).

b. **Post `[GWAITH]`.** Build the comment body:

```
[GWAITH] <pr-or-mr-url>

Branch: <branch>
Base: <base>
Forge: <github|gitlab>
Approved counsel: [COUNSEL vN]
```

Pipe it into the council comment hook for the resolved tracker:

```bash
printf '%s' "$GWAITH_BODY" | <comment-hook> <ticket-id>
```

If the comment hook errors, the PR is already open — surface the error but do not roll back the PR. The user can post the link by hand.

c. **State transition (forged).** After `[GWAITH]` is on the ticket, look up the project's `forged` value in `state_mapping.md` (see "State transition" above). Bootstrap if missing. If the value is empty, skip silently. Otherwise:

```bash
<state-hook> <ticket-id> <forged-value>
```

The hook is idempotent — `noop:` is a normal outcome. On JSON error, surface the message in the report; do not roll back the PR or the comment.

### 9. Cleanup and report

- Switch back to base: `git checkout <base>` so the user is not left on the forge branch.
- If Celebrimbor aborted before opening the PR, delete the local branch: `git branch -D <branch>`.
- If everything succeeded, the local branch may stay (the user may want to inspect it).

Report — one short block:

- The ticket id and a link to the ticket (from the comment hook's success line if `[GWAITH]` was posted).
- The branch name.
- The PR/MR URL (if opened).
- The action taken: `forged` / `aborted (<reason>)` / `dry-run` / `skipped (declined at confirm)` / `error (<reason>)`.

Do not reproduce the smith's full diff — it lives on the PR now.

## Rules

- Single ticket per invocation. No sweep mode.
- Working tree must be clean before the forge starts. Do not stash, do not commit dangling changes.
- Branch name is `<TICKET-ID>-<slug>`. Refuse to overwrite an existing remote branch of that name.
- The smith subagent never pushes and never posts on the ticket. The skill body owns those network writes via the forge hook and the council comment hook.
- `--dry-run` overrides `--confirm` — nothing to confirm if nothing is posted.
- `[GWAITH]` post failure does not roll back the PR. Surface the error and let the user reconcile.
- Do not surface tracker or forge tokens in logs, responses, or saved files.
- Aborts are first-class outcomes, not failures. Name the flaw plainly; do not retry.
