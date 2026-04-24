---
name: council
description: Use when the user runs /council [ticket-id]. Convenes a planning council on an issue tracker ticket. Erestor (subagent) drafts a plan, posts it as a ticket comment, and waits for the human's verdict. Each subsequent invocation refines the plan from the human's reply. Read-only agency — never writes code, opens PRs, or acts on the repo.
user_invocable: true
---

# Council

Convenes a planning council on a tracker ticket. A subagent — Erestor, chief counsellor of Imladris — drafts a plan from the ticket's text. The plan is posted as a comment. The human — Elrond — renders verdict through further comments. Each `/council TICKET-ID` turns the wheel another round.

## Ethos

- **Elrond decides.** The human holds every verdict. The Council never acts in their name.
- **Erestor counsels.** He reads, he drafts, he asks when he must. He does not approve, reject, or act.
- **The thread is the record.** Every plan, every question, every verdict is a comment on the ticket. No side channels.

## Argument parsing

`/council [ticket-id]`

- `ticket-id`: the tracker's ticket identifier (e.g. `YT-123`). If omitted, ask the user via AskUserQuestion.

## Tracker routing

Dispatch by ticket-ID prefix:

| Prefix | Tracker | Fetch script | Comment script |
|---|---|---|---|
| `YT-…` | YouTrack | `~/.claude/hooks/council-youtrack-fetch.sh` | `~/.claude/hooks/council-youtrack-comment.sh` |

If the prefix does not match any supported tracker, tell the user it is not yet wired and stop.

---

## YouTrack Workflow

### 1. Load YouTrack config

Determine the memory directory for this project: `<claude-root>/projects/<pwd-slugified>/memory/` where `<pwd-slugified>` is the current working directory with path separators replaced by dashes (see how jira-daily resolves it).

Check memory file `council_youtrack.md` for:

- `YOUTRACK_URL` — e.g. `https://your-org.youtrack.cloud`

If not found, ask the user for the URL via AskUserQuestion, then save to memory:

- Write the file under that memory directory with the standard frontmatter pattern.
- Add a one-line pointer to `MEMORY.md`.

Require `YOUTRACK_TOKEN` env var. If not set, stop and tell the user:

> Set `YOUTRACK_TOKEN` in your environment with a YouTrack permanent token from `<YOUTRACK_URL>/users/me?tab=account-security`.

### 2. Fetch the ticket and its comment thread

Invoke the fetch script with the ticket ID and the URL exported into the environment:

```bash
YOUTRACK_URL=<from-memory> ~/.claude/hooks/council-youtrack-fetch.sh <TICKET-ID>
```

(`YOUTRACK_TOKEN` is already in the shell environment; do not echo or log it.)

The script prints a single JSON object:

```json
{
  "summary": "...",
  "description": "...",
  "comments": [
    { "author": "...", "login": "...", "text": "...", "created": 1700000000000 },
    ...
  ]
}
```

If the script prints `{"error": "..."}`, tell the user the error and stop.

### 3. Parse the thread

Walk the `comments` array (already oldest-first). Determine:

- **Latest plan version.** The highest `N` where a comment's first line matches `[PLAN vN]` (case-insensitive). If no plan exists yet, the next version is `1`.
- **Latest human reply.** Any comments after the last `[PLAN vN]` whose first line is *not* one of the Council tokens (`[PLAN v…]`, `[AGENT-ASK]`). These are Elrond's counsel.
- **Verdict.** Scan the latest human reply for `[APPROVE]` or `[REJECT]` (case-insensitive, anywhere in the body).

### 4. Handle verdict

If `[APPROVE]` is present: tell the user the council has adjourned with approval on `[PLAN vN]`. Do not post anything. Stop.

If `[REJECT]` is present: tell the user the council has adjourned without approval. Do not post anything. Stop.

### 5. Check turn limit

If the next plan would be `[PLAN v6]` (i.e. five rounds already posted without verdict), do not draft. Post a single `[AGENT-ASK]` comment via the comment script with this body:

```
[AGENT-ASK] The council has turned five times without a verdict. This thread has outgrown what a comment can resolve. Take it offline — a conversation, a design doc, or a fresh ticket narrowed to one open question.
```

Then stop.

### 6. Summon Erestor

Load the Erestor prompt from `<skill-dir>/erestor.md` (read the file contents). Dispatch a subagent via the Agent tool, `subagent_type: general-purpose`, passing:

- The Erestor prompt as the *system/instruction* portion of the Agent call's `prompt`.
- A tail block containing:
  - The ticket `summary` and `description`.
  - The full comment thread (all `[PLAN v…]`, `[AGENT-ASK]`, and human comments in order, with author names).
  - The instruction: "You are drafting `[PLAN v{NEXT}]`. If a clarifying question is more honest than a guess, reply with a single `[AGENT-ASK]` instead."

Erestor returns a single markdown body whose first line begins with either `[PLAN v{NEXT}]` or `[AGENT-ASK]`. If he returns anything else, treat it as a drafting failure and stop — do not post.

### 7. Post the comment

Pipe Erestor's body into the comment script:

```bash
printf '%s' "$EREST_OR_BODY" | YOUTRACK_URL=<from-memory> ~/.claude/hooks/council-youtrack-comment.sh <TICKET-ID>
```

If the script exits non-zero or prints an error, tell the user and stop.

### 8. Report

Tell the user, in one short block:

- The ticket ID.
- Which token was posted (`[PLAN vN]` or `[AGENT-ASK]`).
- The ticket URL so they can go render verdict: `<YOUTRACK_URL>/issue/<TICKET-ID>`.

Do not reproduce Erestor's draft in the response — it lives on the ticket now.

---

## Comment grammar

Exactly four tokens carry state. Everything else is counsel.

| Token | Who writes it | Meaning |
|---|---|---|
| `[PLAN vN]` | Erestor | A draft of the plan. N increments each round. |
| `[AGENT-ASK]` | Erestor | A single clarifying question. |
| `[APPROVE]` | Elrond | The plan stands. Council adjourns. |
| `[REJECT]` | Elrond | The plan is abandoned. Council adjourns. |

Human replies between these tokens are free-form prose — Erestor reads them as counsel, never as commands.

## Rules

- Never act on Elrond's behalf. The skill only reads tickets and posts comments.
- Never edit or delete existing comments. Every round is a new comment.
- If `YOUTRACK_TOKEN` is unset, stop and tell the user — do not proceed.
- Turn limit is five plans per ticket. On the sixth, post `[AGENT-ASK]` asking to take the thread offline.
- Case-insensitive matching of `[APPROVE]`, `[REJECT]`, `[PLAN vN]`, `[AGENT-ASK]`.
- Trackers other than YouTrack are not yet wired. Do not guess.
- Do not surface `YOUTRACK_TOKEN` in logs, responses, or saved files.
