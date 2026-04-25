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

Today only YouTrack is wired. Route every ticket ID to:

- Fetch: `~/.claude/hooks/council-youtrack-fetch.sh`
- Comment: `~/.claude/hooks/council-youtrack-comment.sh`

The ticket prefix (`YT-`, `MET-`, etc.) is whatever YouTrack's project shortName happens to be — do not gate on it. When a second tracker lands, this section will spell out a real dispatch rule (likely a `--tracker` flag or a project-scoped memory pointer).

---

## Working-directory contract

The skill is invoked from inside the repository the ticket concerns. Erestor inherits this working directory and may read it (Read, Grep, Glob, `git log`) to verify assumptions before drafting. He must not modify anything. If the ticket concerns a repo other than the one Claude Code was opened in, the user is expected to `cd` there before running `/council`.

## YouTrack Workflow

### 1. YouTrack config

URL and token both live on a single Vaultwarden item named `youtrack` — URI field for the server URL, password field for the permanent token. The fetch and comment scripts resolve both fields themselves via `secret.sh youtrack uri` and `secret.sh youtrack password`, falling back to `$YOUTRACK_URL` / `$YOUTRACK_TOKEN` env vars when the vault is unreachable. No memory file is required.

If a script reports `YOUTRACK_URL not found` or `YOUTRACK_TOKEN not found`, direct the user to unlock the vault (`bw unlock`, `bw serve --port 8087 &`) and ensure the `youtrack` item carries both URI and password, or export the matching env var. The token itself comes from `<YOUTRACK_URL>/users/me?tab=account-security`.

### 2. Fetch the ticket and its comment thread

Invoke the fetch script with just the ticket ID — URL and token are resolved inside:

```bash
~/.claude/hooks/council-youtrack-fetch.sh <TICKET-ID>
```

(The script pulls both URL and token via the secret helper; do not echo or log them.)

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
- **Bot's last word.** The most recent comment authored by the Council (login is the service account, e.g. `claude`, OR — when no service account is in use — first line carries `[PLAN v…]` / `[AGENT-ASK]`). If no bot comment exists yet, this is the first turn.
- **Fresh counsel.** Any comments after the bot's last word, authored by a non-bot login. These are Elrond's counsel. If none exist, the thread has not moved since the bot last spoke.
- **Verdict.** Scan the fresh counsel for `[APPROVE]` or `[REJECT]` (case-insensitive, anywhere in the body).

### 4. Handle thread state

The order of these checks matters — verdict beats fresh-counsel check beats first-turn.

1. **Verdict present.** If `[APPROVE]` is in fresh counsel: tell the user the council has adjourned with approval on `[PLAN vN]`. If `[REJECT]`: adjourned without approval. Post nothing. Stop.

2. **No fresh counsel and a plan already exists.** The bot has spoken last and Elrond has not replied. Do not draft, do not post — there is no new ground to chew on, and a re-issue would only clutter the thread. Tell the user: "Awaiting Elrond's reply on `[PLAN vN]` (or the latest `[AGENT-ASK]`). No fresh counsel since `<timestamp>`." Stop. **This makes the skill loop-safe** — repeated invocations between Elrond's replies are no-ops.

3. **First turn (no plan yet).** Skip to step 5 to draft `[PLAN v1]`. The ticket itself is the counsel; no prior bot word is required.

4. **Fresh counsel without verdict.** Fall through to the turn-limit check, then summon Erestor.

### 5. Check turn limit

The limit is on `[PLAN vN]` count, not invocation count — `[AGENT-ASK]` posts do not count. If the next plan would be `[PLAN v6]` (i.e. five plan-versions already posted without verdict), do not draft. Post a single `[AGENT-ASK]` comment via the comment script with this body:

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
  - The repo root (`git rev-parse --show-toplevel`) so Erestor knows where his read-tools point.
  - The instruction: "You are drafting `[PLAN v{NEXT}]`. The working directory is the repo this ticket concerns; you may read it (no writes) to verify assumptions before drafting. If a clarifying question is more honest than a guess, reply with a single `[AGENT-ASK]` instead."

Erestor returns a single markdown body whose first line begins with either `[PLAN v{NEXT}]` or `[AGENT-ASK]`. If he returns anything else, treat it as a drafting failure and stop — do not post.

### 7. Post the comment

Pipe Erestor's body into the comment script:

```bash
printf '%s' "$EREST_OR_BODY" | ~/.claude/hooks/council-youtrack-comment.sh <TICKET-ID>
```

On success the script prints one line:

```
posted: id=<comment-id> created=<epoch-ms> url=<full-ticket-url>
```

On failure it prints `{"error":"...","response":"..."}` (the `response` field carries the server's actual error body). If the script exits non-zero, tell the user the error and stop.

### 8. Report

Tell the user, in one short block:

- The ticket ID.
- Which token was posted (`[PLAN vN]` or `[AGENT-ASK]`).
- The ticket URL printed on the success line in step 7.

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
- **Loop-safe.** If no fresh counsel from Elrond has come since the bot's last word, post nothing. Repeated invocations between Elrond's replies must be silent no-ops. The thread, not the invocation count, is the source of truth.
- If the secret helper cannot resolve `YOUTRACK_TOKEN` (neither Vaultwarden nor env), the fetch/comment script returns an error; surface it and stop — do not proceed.
- Turn limit is five plans per ticket. On the sixth, post `[AGENT-ASK]` asking to take the thread offline. (Only triggers when fresh counsel exists; otherwise the loop-safe rule keeps the thread quiet.)
- Case-insensitive matching of `[APPROVE]`, `[REJECT]`, `[PLAN vN]`, `[AGENT-ASK]`.
- Trackers other than YouTrack are not yet wired. Do not guess.
- Do not surface `YOUTRACK_TOKEN` in logs, responses, or saved files.
