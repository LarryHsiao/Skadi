# Gwaihir — Unified Inbound Comms Lens (Design)

**Date:** 2026-07-07
**Status:** Design — awaiting review

## Purpose

One read-only brief answering *"what came in that needs me?"* across both mail
and Teams. Gwaihir gathers word arriving from afar — Outlook mail and Microsoft
Teams messages — and lays the few items worth a human eye before the user in a
single view.

Gwaihir **surfaces; it does not act.** The deeper verbs — mark-read, move,
draft-a-reply — stay with `/triage` (mail) and `/vor` (Teams). A footer hint
points there.

It is the communications analog of `/palantír`, which already unites two forges
(GitHub PRs + GitLab MRs) under one read-only view. Gwaihir does the same one
rung over, for inbound conversation.

## Non-goals

- **No drafting.** Suggesting Teams replies stays `/vor`'s job. Gwaihir names
  which threads want a reply; it does not compose one.
- **No mail account-switching.** Gwaihir reads the default Outlook account only.
  For a non-default mailbox, run `/triage <account>` directly.
- **No mutation.** No mark-read, move, post, or run-stamp. Gwaihir never writes.
- **No new hook.** Gwaihir is pure orchestration over primitives that already
  exist and are already tested.

## Approach

Three data-path options were weighed:

- **(A) Orchestrate the primitives directly — chosen (palantír's way).**
  Gwaihir calls the low-level pieces the two skills already lean on: the
  `outlook_email_search` connector tool for mail, `vor-teams-poll.sh` for
  Teams, `outlook-classify.sh` for the user's mail override rules. It adds no
  new hook.
- **(B) Invoke `/triage` and `/vor` as sub-skills, merge their output —
  rejected.** Each renders its own full report, offers, and run-stamp; merging
  two chat renders is messy and fires double prompts.
- **(C) Re-implement fetch + classify inline — rejected.** Clones logic that
  lives (and drifts) elsewhere.

Approach A is the thinnest thing that works and mirrors how `/palantír` unites
its two forges through their check hooks.

## Arguments

`/gwaihir [channel] [hours]` — order-independent, both optional.

- `mail` → mail channel only.
- `teams` → Teams channel only.
- A bare integer → the mail lookback window in hours (default `24`). Mirrors
  `/triage`'s `hours` arg. Ignored when scope is `teams` (Teams has no window;
  its poller reads the delta since last cursor).
- No args → both channels, 24h mail window.

Examples:

```
/gwaihir            both channels, 24h mail window
/gwaihir mail 48    mail only, 48h
/gwaihir teams      Teams only
/gwaihir 6          both channels, last 6h of mail
```

If the integer is non-numeric or absent, default to 24 without prompting.

## Data flow

### 1. Parse args

Resolve channel scope (`mail` | `teams` | both) and the mail window `hours`.

### 2. Mail (skipped when scope is `teams`)

Read through the **Microsoft 365 claude.ai connector**, exactly as `/triage`
does — the connector is read-only and drives the fetch. Locate
`mcp__claude_ai_Microsoft_365__outlook_email_search` (a deferred tool; load its
schema with ToolSearch first). If no Microsoft 365 mail tool is present in the
session, the connector is not connected → mark the **mail source unavailable**
and footer-note it; do not fall back to `outlook-fetch.sh`.

Fetch inbox messages received within the last `hours`, unread only. Then
classify each, keeping only **Worth a look**; the rest become a single routine
count.

**Classification is the single source of truth in `/triage` §2 — Gwaihir
references it, does not restate it.**

- **User overrides** via `~/.claude/hooks/outlook-classify.sh "<from>"
  "<subject>"` (default account), which prints `worth`, `routine`, or
  `default`.
- **Residual `default`** verdicts are judged by the same Worth-a-look heuristic
  named in `/triage` §2 (high importance; open/escalated monitoring alerts;
  bank/gov non-routine; a real human writing directly; explicit action-by-date).
  When in doubt, prefer routine.

The account is the default from `outlook_accounts.md` (or legacy single-account
compat when the memory file is absent). Gwaihir does not expose account
selection.

### 3. Teams (skipped when scope is `mail`)

Run `~/.claude/hooks/vor-teams-poll.sh` and handle its exit code first:

- `2` — dormant (no `sources.txt`, or no `vor-graph-token`). Mark the **Teams
  source unavailable** with reason "dormant — tenant consent pending";
  footer-note it.
- `3` — a tool (`jq`/`curl`) is missing. Mark Teams unavailable, naming the tool.
- `4` — Graph denied or errored. Mark Teams unavailable with reason "consent
  for Chat.Read/ChannelMessage.Read.All not yet granted".
- `0` — proceed. Stdout is a JSON array of normalized messages
  (`{id, sender, text, thread, timestamp, mentionsMe}`); an empty array means
  nothing new.

Organize as `/vor` does: surface threads where `mentionsMe` is true, then
threads asking a direct question; collapse the rest into a routine count. Drop
pure noise (joins, reactions, automated notices). **Do not draft replies** — name
the threads that want one and point to `/vor`.

### 4. Render

One combined brief. Both halves present when both answered; a silent half is
replaced by a footer-note naming the gap.

```
Gwaihir — N mail · M threads need you
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📧 Mail — Worth a look (N)
  <YYYY-MM-DD HH:MM>  <sender, ≤24 chars>  <subject, ≤60 chars>
  ...
💬 Teams — Need a reply (M)
  <thread, ≤24 chars>  <@you: | Q:> <text, ≤60 chars>
  ...
· Routine: mail K · teams J
───────────────────────────────────
  for mail actions: /triage    for Teams drafts: /vor
```

- Header counts are the surfaced (worth-a-look / needs-reply) totals only.
- Routine line is a single per-channel tally, omitted for a channel with zero
  routine or one that was unavailable.
- Mail rows sorted newest-first; Teams threads ordered mentions-first, then
  direct-question, then any remaining surfaced.

**Degraded and empty cases:**

- A silent source is replaced with a footer line, e.g.
  `Teams: dormant — tenant consent pending` or
  `Mail: connector not connected — enable it at claude.ai → Settings → Connectors`.
- Scope `mail` or `teams` renders only that half; the other is neither queried
  nor noted.
- **Both silent (or both empty):** render only

  ```
  Gwaihir — nothing to look through.
  ```

  with, beneath it, any source-gap footer notes so the user knows *why* it is
  empty (dormant vs. genuinely quiet).

## Read-only guarantee

Gwaihir issues only read-shaped calls: the connector's `outlook_email_search`,
the `vor-teams-poll.sh` GET poller, and the `outlook-classify.sh` lookup. It has
no mark-read, no move, no post, no draft-send, and no run-stamp. Never add one —
mutation is explicitly out of scope; the acting verbs live in `/triage` and
`/vor`.

## Testing

Gwaihir adds no new shell code, so it carries no new hook tests — its
primitives (`vor-teams-poll.sh`, `outlook-classify.sh`) are already covered by
their own suites, and the connector is an in-session tool.

Verification is a manual dry-run of the render logic against sample inputs:

1. **Happy path** — sample connector output (a mix of worth/routine) + a `vor`
   fixture with one `mentionsMe` thread → the combined brief shows both halves
   with correct counts and ordering.
2. **Teams dormant** — `vor-teams-poll.sh` exit 2 → mail half renders, Teams
   footer-notes "dormant — tenant consent pending".
3. **Connector absent** — no Microsoft 365 tool in session → Teams half
   renders, mail footer-notes "connector not connected".
4. **Both silent** — connector absent + Teams dormant → single
   "nothing to look through" line plus both gap notes.
5. **Scope** — `/gwaihir mail 48` queries only mail over 48h; `/gwaihir teams`
   queries only Teams and ignores any window.

## Files

- `skills/gwaihir/SKILL.md` — the skill (new).
- No new hooks. No `settings.json` change (all called hooks are already
  allowlisted for `/triage` and `/vor`).
- Propagated to every config root via `/install`.
