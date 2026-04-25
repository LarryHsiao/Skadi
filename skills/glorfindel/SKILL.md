---
name: glorfindel
description: Use when the user runs /glorfindel <tracker> <project> [--filter <id-or-jql>] [--dry-run] [--confirm]. Sweeps every open ticket in the named project, runs the council machinery on each, and aggregates one report. Loop-safe per ticket; opt-in to confirmation prompts before posting.
user_invocable: true
---

# Glorfindel — The Sweep

Glorfindel rode out from Rivendell to seek the Ringbearer, and visited each road in turn until he found him. So this skill: it visits every open ticket in a project, summons the council on those that have stirred, and brings back one report of all.

## Ethos

- **Glorfindel rides; the council still decides.** Per-ticket behavior matches `/council` exactly. Glorfindel never posts more than `/council` would.
- **Loop-safe by inheritance.** A sweep over a project where nothing has moved is a quiet ride — no posts, just a report saying so.
- **The tracker is the home of the work.** Glorfindel reports across many tickets, but the per-ticket record stays on the tracker.

## Argument parsing

`/glorfindel <tracker> <project> [--filter <filter>] [--dry-run] [--confirm]`

| Argument | Required | Meaning |
|---|---|---|
| `<tracker>` | yes | `youtrack` (alias `yt`) or `jira` |
| `<project>` | yes | Project shortName / key (e.g. `MET`, `PSG`) |
| `--filter <filter>` | no | Tracker-aware extra scope (see below) |
| `--dry-run` | no | List what would happen; never post |
| `--confirm` | no | Ask before each post (default off) |

**Filter semantics:**

- **YouTrack:** an extra query fragment, ANDed with the project clause. Example: `--filter "state:Open assignee:me"`. If omitted, defaults to `#Unresolved`.
- **Jira:** either a saved filter ID (all-digit, e.g. `--filter 10363`) OR a JQL fragment ANDed with the project (e.g. `--filter "assignee = currentUser()"`). If omitted, defaults to `statusCategory != Done`.

## Tracker routing

| Tracker | List hook | Council fetch | Council comment |
|---|---|---|---|
| `youtrack` / `yt` | `~/.claude/hooks/glorfindel-youtrack-list.sh` | `~/.claude/hooks/council-youtrack-fetch.sh` | `~/.claude/hooks/council-youtrack-comment.sh` |
| `jira` | `~/.claude/hooks/glorfindel-jira-list.sh` | `~/.claude/hooks/council-jira-fetch.sh` | `~/.claude/hooks/council-jira-comment.sh` |

## Workflow

### 1. Pre-flight check

If `<tracker>` is `jira` and neither `--dry-run` nor `--confirm` is set: warn the user via AskUserQuestion that Glorfindel is about to sweep Jira and may post automatically to many real tickets. Offer three options:
- Proceed unattended (risky on Jira).
- Re-run with `--confirm` (recommended).
- Re-run with `--dry-run` (safest).

If the user picks "proceed unattended" explicitly, continue. Otherwise stop and tell them how to re-invoke.

### 2. List the open tickets

Invoke the chosen list hook:

```bash
<list-hook> <PROJECT> [<FILTER>]
```

The hook prints a JSON array `[{id, summary}]`. If it prints `{"error": ...}`, surface it and stop. If the array is empty, tell the user *"The road lies empty — no tickets matching the scope."* and stop.

### 3. For each ticket — run the council

Iterate the list (newest-first as the hook returns it). For each ticket, follow the **council workflow** (see `skills/council/SKILL.md` steps 1 through 6) with two glorfindel-specific shifts:

- **Loop-safe is mandatory.** Skip silently any ticket whose state classifies as "no fresh counsel". Do not draft, do not post — they are at rest. Record action `quiet` and move on.
- **Posting gate** — applies any time the per-ticket flow would invoke the comment hook:
  - If `--dry-run` is on: do *not* invoke the comment hook. Record what *would* have been posted (token, body length).
  - If `--confirm` is on: ask the user via AskUserQuestion (one ticket per question, with the proposed token and a 2-line excerpt). On rejection: skip the post; record `skipped`. On approval: post.
  - Otherwise: post.

Erestor's draft is per-ticket — each ticket gets its own subagent dispatch with its own thread context.

If a hook fails mid-sweep (auth, network, server error), record the ticket as `error` with the message and continue with the rest. Do not let one ticket's failure halt the sweep.

### 4. Aggregate the report

Print one markdown table summarizing the ride. Example shape:

```
**Glorfindel — sweep of youtrack:MET**

| Ticket | Action     | Detail                              |
|--------|------------|-------------------------------------|
| MET-3  | drafted    | [PLAN v1] posted (id 7-22)          |
| MET-2  | dry-run    | [PLAN v2] would post (412 chars)    |
| MET-1  | quiet      | awaiting reply on [PLAN v4]         |

Total: 3 tickets — 1 drafted, 1 dry-run, 1 quiet, 0 adjourned, 0 talked-out, 0 skipped, 0 errors.
```

Action vocabulary:

| Action | Meaning |
|---|---|
| `quiet` | Loop-safe no-op — bot's last word stands; no fresh Elrond counsel. |
| `drafted` | Erestor wrote a `[PLAN vN]` or `[AGENT-ASK]` and the post landed. |
| `dry-run` | Erestor's draft prepared; not posted per `--dry-run`. |
| `adjourned` | `[APPROVE]` or `[REJECT]` found in fresh counsel; council closed. |
| `talked-out` | Five-plan turn limit hit; canned `[AGENT-ASK]` posted (or would-post under dry-run). |
| `skipped` | User declined the `--confirm` prompt for this ticket. |
| `error` | A hook failed for this ticket. Include the error message in Detail. |

Do not reproduce Erestor's full drafts in the report — they live on the tickets (or stayed in dry-run memory). Print one URL per ticket only when the action carries an id (drafted / talked-out).

## Rules

- Glorfindel never posts more than the council would. Per-ticket behavior matches `/council` exactly.
- `--dry-run` overrides `--confirm` — nothing to confirm if nothing is posted.
- Errors on one ticket do not stop the sweep. Record and continue.
- Sweep order is the order returned by the list hook.
- **Jira sweeps require deliberate intent.** When tracker is `jira` without `--dry-run` or `--confirm`, prompt before proceeding (step 1).
- Do not surface tracker tokens in logs, responses, or saved files.
- Do not invent ticket IDs not returned by the list hook. The list is the authoritative scope.
