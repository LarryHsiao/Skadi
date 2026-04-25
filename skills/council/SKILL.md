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

Two trackers are wired today:

| Tracker | Fetch hook | Comment hook |
|---|---|---|
| YouTrack | `~/.claude/hooks/council-youtrack-fetch.sh` | `~/.claude/hooks/council-youtrack-comment.sh` |
| Jira | `~/.claude/hooks/council-jira-fetch.sh` | `~/.claude/hooks/council-jira-comment.sh` |

**Hybrid dispatch rule.** Resolve the tracker for a given `/council [tracker:]TICKET-ID` invocation in this order:

1. **Explicit override.** If the argument carries a tracker prefix — `youtrack:MET-1`, `yt:MET-1`, `jira:PSG-4264` — that wins. Strip the prefix and use the remainder as the ticket ID. Accept `youtrack` or `yt`; accept `jira`. Case-insensitive.
2. **Per-project memory.** Read `tracker_routing.md` from the project memory directory. The file maps a project key prefix to a tracker:

   ```markdown
   ---
   name: Tracker Routing
   description: Project-key prefix to tracker mapping for /council and /glorfindel.
   type: reference
   ---

   - MET → youtrack
   - PSG → jira
   ```

   Match the prefix of the ticket ID (`MET-1` → prefix `MET`) against the table; if found, use the named tracker.
3. **Ask.** No prefix override, no memory mapping — ask the user via AskUserQuestion which tracker to use, then offer to save the mapping to memory for next time.

Once the tracker is chosen, all subsequent steps use that backend's hooks. The ticket-ID prefix itself is just a project shortName; do not hardcode any list of valid prefixes.

**Jira read-only rule.** When smoke-testing or otherwise running the council in a non-production capacity, treat Jira tickets as read-only — do not post comments. The Jira comment hook accepts `COUNCIL_DRY_RUN=1` in env to print the would-be ADF payload instead of posting. Use that for shape verification.

---

## Working-directory contract

The skill is invoked from inside the repository the ticket concerns. Erestor inherits this working directory and may read it (Read, Grep, Glob, `git log`) to verify assumptions before drafting. He must not modify anything. If the ticket concerns a repo other than the one Claude Code was opened in, the user is expected to `cd` there before running `/council`.

## Workflow

### 0. Resolve the tracker

Apply the **Hybrid dispatch rule** from "Tracker routing" above to choose between YouTrack and Jira. The remainder of these steps refer to `<fetch-hook>` and `<comment-hook>` — substitute the chosen tracker's pair from the routing table.

**YouTrack credentials.** One Vaultwarden item named `youtrack`: URI = server URL, password = permanent token. Hooks resolve via `secret.sh youtrack uri` / `secret.sh youtrack`. Env fallback: `$YOUTRACK_URL` / `$YOUTRACK_TOKEN`. Token comes from `<YOUTRACK_URL>/users/me?tab=account-security`.

**Jira credentials.** One Vaultwarden item named `jira`: URI = `https://<your>.atlassian.net`, username = your email, password = an API token. Hooks resolve via `secret.sh jira uri` / `secret.sh jira username` / `secret.sh jira password JIRA_API_TOKEN`. Env fallback: `$JIRA_BASE_URL` / `$JIRA_EMAIL` / `$JIRA_API_TOKEN`. Token comes from `https://id.atlassian.com/manage-profile/security/api-tokens`.

If any credential cannot be resolved, the hook prints `{"error":"jira credentials missing"}` (or YouTrack equivalent) — surface it and stop.

### 1. Fetch the ticket and its comment thread

Invoke the chosen tracker's fetch script with just the ticket ID — credentials are resolved inside:

```bash
<fetch-hook> <TICKET-ID>
```

(The script pulls every credential via the secret helper; do not echo or log them.)

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

### 2. Parse the thread

Walk the `comments` array (already oldest-first). Determine:

- **Latest plan version.** The highest `N` where a comment's first line matches `[COUNSEL vN]` or its alias `[PLAN vN]` (case-insensitive). If no plan exists yet, the next version is `1`.
- **Bot identity.** Two modes:
  - **Service-account mode** (e.g. YouTrack with a dedicated `claude` user): a comment is the bot's iff `login == "<bot-login>"`.
  - **Shared-identity mode** (e.g. Jira where the bot posts as Elrond): no login distinction exists; a comment is the bot's iff its first line carries `[COUNSEL v…]` / `[PLAN v…]` (alias) or `[PARLEY]` / `[AGENT-ASK]` (alias).

  Detect mode by inspecting the comment thread: if any login carries the configured bot value (today: `claude`), use service-account mode; otherwise use shared-identity mode.

- **Bot's last word.** The most recent comment classified as the bot's under the chosen mode. If no bot comment exists yet, this is the first turn.
- **Fresh counsel.** Any comments after the bot's last word that are *not* the bot's under the chosen mode. These are Elrond's counsel. If none exist, the thread has not moved since the bot last spoke.
- **Verdict.** Scan the fresh counsel for any of these tokens (case-insensitive, anywhere in the body): `[FORTH]` or its alias `[APPROVE]` (yes); `[NAY]` or its alias `[REJECT]` (no); `[NAMARIE]` or its alias `[FAREWELL]` (adjourn without verdict).

### 3. Handle thread state

The order of these checks matters — verdict beats fresh-counsel check beats first-turn.

1. **Verdict present.** Scan all fresh counsel for the three verdict tokens (and their aliases). Token precedence — *not* chronological order — picks the winner: `[FORTH]`/`[APPROVE]` beats `[NAY]`/`[REJECT]` beats `[NAMARIE]`/`[FAREWELL]`. So if Elrond posts `[NAY]` and later posts `[FORTH]`, the parser adjourns as approved (FORTH wins regardless of when it appeared); same if the order is reversed. Effect:
   - `[FORTH]`/`[APPROVE]` → adjourn with approval on `[COUNSEL vN]`.
   - `[NAY]`/`[REJECT]` → adjourn without approval.
   - `[NAMARIE]`/`[FAREWELL]` → adjourn without verdict (farewell — for out-of-band resolution).
   
   Tell the user which adjournment fired and on which counsel version. Post nothing. Stop.

2. **No fresh counsel and a plan already exists.** The bot has spoken last and Elrond has not replied. Do not draft, do not post — there is no new ground to chew on, and a re-issue would only clutter the thread. Tell the user: "Awaiting Elrond's reply on `[COUNSEL vN]` (or the latest `[PARLEY]`). No fresh counsel since `<timestamp>`." Stop. **This makes the skill loop-safe** — repeated invocations between Elrond's replies are no-ops.

3. **First turn (no plan yet).** Skip to step 4 to draft `[COUNSEL v1]`. The ticket itself is the counsel; no prior bot word is required.

4. **Fresh counsel without verdict.** Fall through to the turn-limit check, then summon Erestor.

### 4. Check turn limit

The limit is on `[COUNSEL vN]` count, not invocation count — `[PARLEY]` posts do not count. If the next plan would be `[COUNSEL v6]` (i.e. five counsels already posted without verdict), do not draft. Post a single `[PARLEY]` comment via the comment script with this body:

```
[PARLEY] The council has turned five times without a verdict. This thread has outgrown what a comment can resolve. Take it offline — a conversation, a design doc, or a fresh ticket narrowed to one open question.
```

Then stop.

### 5. Summon Erestor

Load the Erestor prompt from `<skill-dir>/erestor.md` (read the file contents). Dispatch a subagent via the Agent tool, `subagent_type: general-purpose`, passing:

- The Erestor prompt as the *system/instruction* portion of the Agent call's `prompt`.
- A tail block containing:
  - The ticket `summary` and `description`.
  - The full comment thread (all `[COUNSEL v…]`, `[PARLEY]`, and human comments in order, with author names).
  - The repo root (`git rev-parse --show-toplevel`) so Erestor knows where his read-tools point.
  - The instruction: "You are drafting `[COUNSEL v{NEXT}]`. The working directory is the repo this ticket concerns; you may read it (no writes) to verify assumptions before drafting. If a clarifying question is more honest than a guess, reply with a single `[PARLEY]` instead."

Erestor returns a single markdown body whose first line begins with either `[COUNSEL v{NEXT}]` or `[PARLEY]`. If he returns anything else, treat it as a drafting failure and stop — do not post.

### 6. Post the comment

Pipe Erestor's body into the chosen tracker's comment script:

```bash
printf '%s' "$EREST_OR_BODY" | <comment-hook> <TICKET-ID>
```

On success the script prints one line in the same shape regardless of tracker:

```
posted: id=<comment-id> created=<epoch-ms> url=<full-ticket-url>
```

On failure it prints `{"error":"...","response":"..."}` (the `response` field carries the server's actual error body). If the script exits non-zero, tell the user the error and stop.

### 7. Report

Tell the user, in one short block:

- The ticket ID.
- Which token was posted (`[COUNSEL vN]` or `[PARLEY]`).
- The ticket URL printed on the success line in step 6.

Do not reproduce Erestor's draft in the response — it lives on the ticket now.

---

## Comment grammar

Six tokens carry state. Everything else is counsel.

| Token (primary) | Accepted alias | Who writes it | Meaning |
|---|---|---|---|
| `[COUNSEL vN]` | `[PLAN vN]` | Erestor | A draft of the plan. N increments each round. The counsellor's counsel. |
| `[PARLEY]` | `[AGENT-ASK]` | Erestor | A single clarifying question — speech between sides to come to terms. |
| `[MELLON]` | `[FRIEND]` | Elrond | Summons. *Speak, friend, and enter* — enrolls a ticket in `/glorfindel` sweeps. Ignored by single-ticket `/council` (the invocation itself is consent). |
| `[FORTH]` | `[APPROVE]` | Elrond | The plan stands. *Forth, Eorlingas!* Council adjourns. |
| `[NAY]` | `[REJECT]` | Elrond | The plan is abandoned. Council adjourns. |
| `[NAMARIE]` | `[FAREWELL]` | Elrond | *Farewell.* Adjourn without verdict — when the thread closes for reasons other than approval or rejection (resolved out-of-band, ticket subsumed by another, etc.). |

The English aliases (`[PLAN vN]`, `[AGENT-ASK]`, `[FRIEND]`, `[APPROVE]`, `[REJECT]`, `[FAREWELL]`) are accepted equivalents, recognized everywhere their Tolkien primaries are. Use either form; the parser treats them identically. User-facing reports prefer the Tolkien token.

Human replies between these tokens are free-form prose — Erestor reads them as counsel, never as commands.

## Rules

- Never act on Elrond's behalf. The skill only reads tickets and posts comments.
- Never edit or delete existing comments. Every round is a new comment.
- **Loop-safe.** If no fresh counsel from Elrond has come since the bot's last word, post nothing. Repeated invocations between Elrond's replies must be silent no-ops. The thread, not the invocation count, is the source of truth.
- If the tracker hook reports a credential is missing, surface the error and stop — do not proceed.
- Turn limit is five counsels per ticket. On the sixth, post `[PARLEY]` asking to take the thread offline. (Only triggers when fresh counsel exists; otherwise the loop-safe rule keeps the thread quiet.)
- Case-insensitive matching of all six tokens and their aliases.
- Two trackers are wired: YouTrack and Jira. The hybrid dispatch rule above chooses between them.
- **Jira tickets are real work.** Do not post test or diagnostic comments to Jira during smoke testing. Use `COUNCIL_DRY_RUN=1` env on the Jira comment hook for shape verification, and do write-path smoke tests against YouTrack (MET-1).
- Do not surface tracker tokens in logs, responses, or saved files.
