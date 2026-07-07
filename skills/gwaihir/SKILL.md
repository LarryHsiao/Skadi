---
name: gwaihir
description: Use when the user runs /gwaihir [channel] [hours]. Gathers Outlook mail and Microsoft Teams messages into one read-only "what needs me?" brief — the communications analog of /palantír. Surfaces the few items worth a look (mail) and the threads that want a reply (Teams); never acts. Renders whichever source answers and footer-notes a silent one (Teams stays dormant until tenant consent). Actions stay with /triage and /vor.
user_invocable: true
---

# Gwaihir — the Windlord's Brief

Gwaihir bears word in from afar. It gathers what arrived in Outlook mail and
Microsoft Teams, lays the few items that need a human eye before you in one
view, and points to `/triage` and `/vor` for the acting. **It reads and
surfaces. It never acts.**

## Arguments

`/gwaihir [channel] [hours]` — order-independent, both optional.

- `mail` → mail channel only.
- `teams` → Teams channel only.
- A bare integer → the mail lookback window in hours (default `24`). Mirrors
  `/triage`. Ignored when scope is `teams` — Teams has no window; its poller
  reads the delta since its last cursor.
- No args → both channels, 24h mail window.

If the integer is non-numeric or absent, default to `24` without prompting.

Examples:

- `/gwaihir` — both channels, 24h mail window
- `/gwaihir mail 48` — mail only, 48h
- `/gwaihir teams` — Teams only
- `/gwaihir 6` — both channels, last 6h of mail

## Workflow

### 1. Mail  *(skip when scope is `teams`)*

Read through the **Microsoft 365 claude.ai connector**, exactly as `/triage`
does — the connector is read-only and drives the fetch.

Locate `mcp__claude_ai_Microsoft_365__outlook_email_search` (a deferred tool;
load its schema with ToolSearch first — `select:mcp__claude_ai_Microsoft_365__outlook_email_search`,
or search `outlook email` if the exact name differs). **If no Microsoft 365 mail
tool is present in the session**, the connector is not connected — set the mail
source unavailable with reason `connector not connected — enable it at
claude.ai → Settings → Connectors` and do nothing further for mail. Do **not**
fall back to `outlook-fetch.sh`.

Fetch inbox messages received within the last `hours`, unread only. Each message
carries at least `subject`, sender name/address, `receivedDateTime`; degrade
gracefully where a field is absent (a missing `importance` never trips the
high-importance rule).

Classify each message, keeping only **Worth a look**; the rest become a single
`routineMail` count. **Classification is `/triage` §2's — reference it, do not
restate it:**

- **User overrides** — `~/.claude/hooks/outlook-classify.sh "<from>" "<subject>"`
  prints `worth`, `routine`, or `default`. Honor `worth`/`routine` directly.
- **Residual `default`** — judge by the Worth-a-look heuristic named in
  `/triage` §2 (high importance; open/escalated monitoring alerts; bank/gov
  non-routine; a real human writing directly; explicit action-by-date). When in
  doubt, prefer routine.

The account is the default from `outlook_accounts.md` (legacy single-account
compat when the memory file is absent). Gwaihir does not expose account
selection.

## Read-only guarantee

<!-- filled by Task 4 -->

## Rules

<!-- filled by Task 4 -->
