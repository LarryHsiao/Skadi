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
| `--skeleton` | no | Carve the skeleton rung (stubs + diagram PNG + `[SKELETON]` comment) and stop. Does not forge code or open a PR. |

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

### Mode: `--skeleton` (the middle rung)

When `--skeleton` is set, celebrimbor carves bones instead of forging code.

1. **Pre-flight** — resolve tracker + source repo only (steps 1a, 1b). No forge,
   no base-branch, no auth check.
2. **Decide + verify rung.** Fetch the thread, run `skeleton-rung.py`. Proceed
   only if the action is `draft_skeleton`, `redraft_skeleton`, or `answer_skeleton`;
   otherwise stop with the action reported (e.g. "awaiting plan approval"). Locate
   the latest `[PLAN]` body — it is the contract. **`answer_skeleton` takes the
   answer path below, not the carve path** (steps 3–8).

   **Answer path (`answer_skeleton`).** Elrond has asked a question of the standing
   `[SKELETON]` (`[CEIST]`/`[ASK]`, or bare prose), not directed a change. Acquire a
   read worktree, summon the skeleton smith in **answer mode** (load
   `skeleton-smith.md`; pass the standing `[SKELETON]` body, the `[PLAN]` body, the
   worktree, and the question). It returns a `[PEDO]` body (or `[ABORT]`).
   - On `[PEDO]`: **append** it as a new comment via `council-youtrack-comment.sh
     <ticket>`, then **edit the `[SKELETON]` comment** via `youtrack-comment-edit.sh
     <ticket> <skeleton_id>`, advancing only its watermark to the newest human
     `created` (body unchanged) — this consumes the question so the next ride stays
     quiet. Report the answer. The bones are never re-carved; only `[ENVINYA]`/`[ALTER]` does that.
   - On `[ABORT]`: post nothing, leave the watermark untouched, and report the
     smith's one-line reason — the question stays open for the next ride.

   Release the worktree on **either** branch. Do **not** continue to steps 3–8.
3. **Acquire a read worktree** (`skadi-worktree.sh acquire <source-repo>`).
4. **Summon the skeleton smith.** Load `<skill-dir>/skeleton-smith.md`; dispatch a
   `general-purpose` subagent with the plan body, the worktree path, and a target
   diagram path under `$TMPDIR` (e.g. `$TMPDIR/skel-<ticket>.mmd` or `.html`).
   It returns a `[FRAME]` block (diagram path + tree/stubs) or `[ABORT]`.
   **`[FRAME]` is the smith's return envelope; the posted comment's token is
   `[SKELETON]` — the same return-vs-comment split celebrimbor already uses for
   `[FORGED]`→`[GWAITH]`. Strip the `[FRAME]`/`diagram:` lines and wrap the
   tree/stubs as the `[SKELETON]` comment.**
5. **Render the PNG.**
   - `.mmd` → `npx -y @mermaid-js/mermaid-cli -i <path>.mmd -o $TMPDIR/skel-<ticket>.png`
   - `.html` → headless screenshot (`npx -y playwright screenshot <path>.html $TMPDIR/skel-<ticket>.png`)
   If the renderer is absent on PATH, stop and report — do not post a skeleton with no diagram.
6. **Attach the PNG:** `~/.claude/hooks/youtrack-attach.sh <ticket> $TMPDIR/skel-<ticket>.png`.
7. **Write the `[SKELETON]` comment** with marker, watermark (= newest human
   `created`), and the smith's tree/stubs:
   - `draft_skeleton` → create via `council-youtrack-comment.sh`.
   - `redraft_skeleton` → edit the existing one via `youtrack-comment-edit.sh <ticket> <skeleton_id>`.

   ```
   [SKELETON] — awaiting [FORTH]
   <!-- consumed: <newest-human-created> -->

   <tree + stubs>
   ```
8. **Release the worktree.** Report the ticket, the action taken, and the attachment.

### 1. Pre-flight resolution

In order:

a. **Tracker** — apply the council hybrid dispatch (see `skills/council/SKILL.md`, "Tracker routing") to bind `<fetch-hook>`, `<comment-hook>`, and `<list-hook>` to YouTrack or Jira.

b. **Source repo** — read `repo_routing.md` for `<tracker>:<project>`. If absent or `(no repo)`, stop with an error — Celebrimbor cannot forge without code. This is the **source repo** the human anchors to; the forge will happen in an isolated workspace, not in this tree.

c. **Forge** — read `forge_routing.md` for `<tracker>:<project>`. If absent, AskUserQuestion (options: `github`, `gitlab`) and save the answer. Resolve the matching forge hook.

d. **Base branch** — `--base` overrides everything. Otherwise read `base_branch.md` keyed by the resolved source repo path. If absent, AskUserQuestion (options: `master`, `main`, plus "Other" affordance) and save.

e. **Forge auth sanity** — `gh auth status` (for github) or `glab auth status` (for gitlab). If either fails, surface the hook's auth-missing error and stop.

There is **no clean-tree gate on the source repo** — Celebrimbor never commits there. The human may be mid-edit on a wholly unrelated branch in the source repo while Celebrimbor forges; the two trees do not collide.

### 2. Build the qualifying-ticket set

If `--ticket <id>` is set, the candidate set is just that one ticket. Otherwise:

- Resolve `--filter` per Glorfindel's filter rules.
- Invoke `<list-hook> <project> [<filter>]` to get the open tickets.
- For each ticket in the list, fetch its thread via `<fetch-hook> <ticket-id>` and apply the **forge gate**:

**YouTrack forge gate (skeleton-stage).** When the tracker is YouTrack, a ticket
qualifies to forge iff `skeleton-rung.py` returns `action=forge` for it:

```bash
~/.claude/hooks/council-youtrack-fetch.sh <ticket> | ~/.claude/hooks/skeleton-rung.py
```

This means: a `[SKELETON]` comment exists and a `[FORTH]` sits past its watermark,
and no `[GWAITH]` yet. The contract the smith implements is the latest `[PLAN]`
body plus the approved `[SKELETON]` body. The Jira path keeps the `[COUNSEL vN]`
gate below.

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

### 5. Workspace and branch

- Compute the branch name: `<TICKET-ID>-<slug>` where slug is the ticket summary, lowercased, ASCII-only, hyphen-separated, capped at ~40 chars. Example: `MET-3-add-session-summary-hook`.
- Check for existing remote branch from the source repo: `git -C <source-repo> ls-remote --exit-code --heads origin <branch>`. If it exists, abort: *"Branch `<branch>` already exists on origin — refuse to overwrite."*
- Acquire an isolated workspace at the base branch via the shared helper:

  ```bash
  ~/.claude/hooks/skadi-worktree.sh acquire <source-repo> <base>
  ```

  The helper prints the workspace path on stdout. It tries `git worktree add` first; on failure (e.g. the human has `<base>` checked out in the source repo) it falls back to a temp clone under `$TMPDIR` and re-points origin at the real remote. Either way the workspace lands on `<base>`, freshly checked out and clean. Hold the path for steps 6 through 9.
- Bring `<base>` to the remote's tip inside the workspace, then cut the new branch off it:

  ```bash
  git -C <workspace> pull --ff-only
  git -C <workspace> checkout -b <branch>
  ```

  If the pull is non-fast-forward, release the workspace and abort with the error.

### 6. Summon Celebrimbor (subagent)

> **YouTrack path:** the smith's contract is the latest `[PLAN]` body **plus** the
> approved `[SKELETON]` body (pass it under a header `## Approved skeleton (your shape)`),
> not a `[COUNSEL vN]`. Everything else in this step is unchanged.

Load the smith prompt from `<skill-dir>/celebrimbor.md`. Dispatch a subagent via the Agent tool, `subagent_type: general-purpose`, passing:

- The Celebrimbor prompt as the *system/instruction* portion.
- A tail block containing:
  - The ticket id, summary, description.
  - The full comment thread (chronological, with author labels).
  - The approved `[COUNSEL vN]` body, called out explicitly under a header like `## Approved counsel (your contract)`.
  - The **repo root** — the workspace path acquired in step 5, not the source repo path. The smith reads, writes, and commits there.
  - The base branch.
  - The branch name (already created on the workspace by step 5).
  - The instruction: *"Implement the Steps of the approved counsel into the repo on the named branch. The branch is already checked out in your working directory — an isolated workspace, not the human's live tree. Commit your work. Do not push, do not open a PR/MR — the hook does that. Return either a `[FORGED]` block or an `[ABORT]` line per your prompt."*

The subagent returns either:

- `[FORGED]` block — extract `branch:`, `title:`, and the body (everything after the title line).
- `[ABORT] <reason>` — go to step 9 (cleanup) and stop with the reason.

Anything else: treat as drafting failure. Go to step 9, surface the malformed return.

### 7. Posting/creation gate

- `--dry-run`: print the parsed branch / title / body length. Skip steps 8 and the `[GWAITH]` post. Go to step 9 — keep the workspace so the user may inspect the smith's commits at `<workspace>/<branch>`; do not release it. Tell the user: *"Dry run — branch `<branch>` exists in the workspace at `<workspace>` with the smith's commits, no push, no PR, no comment. Release the workspace by hand when done with `~/.claude/hooks/skadi-worktree.sh release <workspace>`."*
- `--confirm`: AskUserQuestion showing the branch, title, and the first ~10 lines of the body. On no, go to step 9 (release the workspace; the smith's commits are torn down with it). On yes, proceed.
- Otherwise: proceed.

### 8. Open the PR/MR and post `[GWAITH]`

First push the new branch from the workspace so the forge can see it:

```bash
git -C <workspace> push -u origin <branch>
```

In worktree mode the push reaches origin (the human's real remote) because the workspace shares the source repo's remotes. In clone-fallback mode the helper re-pointed origin at the source repo's origin during acquire, so the push reaches the same remote either way. If the push fails, surface the error and go to step 9 (keep the workspace so the human can inspect; no PR has been opened, no `[GWAITH]` posted).

a. **Open.** Pipe the body into the resolved forge hook (run from inside the workspace so any forge CLI config is consistent):

```bash
printf '%s' "$BODY" | <forge-hook> <branch> <base> <title> <draft-flag>
```

`<draft-flag>` is `--draft` unless `--ready` was set. On success the hook prints `opened: forge=<f> url=<u> number=<n>`. On failure surface the JSON error and go to step 9 — keep the workspace; the branch is on the remote already, the human reconciles by hand.

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

Decide the workspace fate by outcome:

- **Forged successfully** (PR/MR opened, `[GWAITH]` posted): release the workspace. The branch lives on the remote; the human can fetch it into the source repo if they want to inspect it locally.

  ```bash
  ~/.claude/hooks/skadi-worktree.sh release <workspace>
  ```

- **Smith aborted before any commit**: release the workspace; nothing of value was made.
- **Declined at `--confirm`**: release the workspace; the smith's commits are discarded with it.
- **`--dry-run`**: keep the workspace so the user can inspect the smith's commits.
- **PR-open or push failed after the smith forged**: keep the workspace. The branch may already be on the remote (push succeeded but PR-open failed); the smith's commits at minimum live in the workspace. The user reconciles by hand.

No `git checkout <base>` on the source repo is needed — Celebrimbor never modified its HEAD. No `git branch -D <branch>` on the source repo either — the branch lives in the workspace (and on the remote once pushed), not in the source repo.

Report — one short block:

- The ticket id and a link to the ticket (from the comment hook's success line if `[GWAITH]` was posted).
- The branch name.
- The PR/MR URL (if opened).
- The action taken: `forged` / `aborted (<reason>)` / `dry-run` / `skipped (declined at confirm)` / `error (<reason>)`.
- The workspace disposition: `released` / `kept at <path> (<reason>)`.

Do not reproduce the smith's full diff — it lives on the PR now.

## Rules

- Single ticket per invocation. No sweep mode.
- Celebrimbor forges inside an **isolated workspace** acquired in step 5 — a `git worktree` of the source repo (or, on fallback, a temp clone under `$TMPDIR`). The human's source-repo checkout is never modified, never branched on, never required to be clean. The smith reads, writes, and commits only in the workspace.
- Branch name is `<TICKET-ID>-<slug>`. Refuse to overwrite an existing remote branch of that name.
- The smith subagent never pushes and never posts on the ticket. The skill body owns those network writes — the `git push` from the workspace, the forge hook for the PR/MR, the council comment hook for `[GWAITH]`.
- `--dry-run` overrides `--confirm` — nothing to confirm if nothing is posted.
- The workspace is **released on the success path** (PR opened, `[GWAITH]` posted) and **kept on any abort or failure** (including `--dry-run` and `--confirm` declined where the user may want to inspect). The release verb is idempotent; the human may re-run it at any time.
- `[GWAITH]` post failure does not roll back the PR. Surface the error and let the user reconcile.
- Do not surface tracker or forge tokens in logs, responses, or saved files.
- Aborts are first-class outcomes, not failures. Name the flaw plainly; do not retry.
