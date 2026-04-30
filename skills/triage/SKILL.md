---
name: triage
description: Use when the user runs /triage [hours]. Pulls unread Outlook mail from the last N hours (default 24), separates the few items worth attention from routine noise, and renders a tight two-tier summary.
user_invocable: true
---

# Triage

Cuts unread mail down to the few items that deserve a human eye. Everything else is collapsed into a tally.

## Argument

- `hours` — optional integer, defaults to `24`. Window of `receivedDateTime` to fetch.

## Workflow

### 1. Fetch unread mail

```bash
~/.claude/hooks/outlook-fetch.sh <hours>
```

Returns a Microsoft Graph JSON envelope with `value: [...]` of message objects. Each object carries `id`, `subject`, `from.emailAddress.{name,address}`, `receivedDateTime`, `bodyPreview`, `importance`, `webLink`.

If the hook fails (no token, vault locked, network), surface the stderr line plainly and stop. Do not attempt to retry the device-code dance silently.

### 2. Classify each message

Two buckets only — **Worth a look** and **Routine**.

Mark a message **Worth a look** when *any* of these hold:

- `importance == "high"`
- The sender domain is a monitoring or security service (Netdata, Sentry, PagerDuty, Datadog, Grafana, AWS Health, GitHub security alerts, Cloudflare alerts) **and** the subject suggests an open or escalated state (`Critical`, `Raised`, `Failure`, `Down`, `Breach`).
- The sender is a bank, payment provider, or government agency **and** the subject is not a routine receipt or statement (login from new device, suspicious activity, document required).
- The sender is a real human (free-text name, no `noreply`/`no-reply`/`notifications`/`updates` substring in the address) writing directly — not via a list.
- The subject explicitly asks the user for action by a date (`due`, `by Friday`, `before`, `action required`, `please respond`).

Everything else is **Routine**: newsletters, marketing, shipping/receipt notifications, social pings, recovered-state alerts, automated digests.

When in doubt between the two, prefer Routine — false negatives in this skill are recoverable (the message stays in the inbox); false positives drown the signal.

### 3. Render the report

```
Triage — N unread, last <hours>h
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚡ Worth a look (M)
  <YYYY-MM-DD HH:MM>  <sender name, ≤24 chars>  <subject, ≤60 chars>
  ...

· Routine (N - M)
  newsletters: X · marketing: X · receipts: X · alerts (recovered): X · social: X · other: X
```

The Routine line is a single-line tally by sub-category — assign each routine message to one of the labels shown. Omit a label whose count is zero. If the breakdown is uninteresting (everything in one bucket), collapse to `Routine (N - M) — all <label>`.

If `M == 0`, render only the header and the Routine tally; add `✓ Nothing pressing.` underneath.

If `N == 0`, render:

```
Triage — inbox is quiet (last <hours>h).
```

### 4. Offer the next step

After the report, end with **one short line**:

- If there is anything in **Worth a look**: name the most important item and ask whether to open it (paste its `webLink`).
- Else, if Routine count is non-zero: offer to mark the Routine batch as read in one stroke. Do not act yet — wait for the word. (Mark-as-read is a separate, future hook.)
- Else: nothing — the inbox is quiet.

## Rules

- Never reveal the body content of a message in the report — the subject and sender are enough. The user can open the `webLink` if curious.
- Never bulk-archive or mark-as-read on the user's behalf without an explicit yes for that batch.
- Do not call `outlook-fetch.sh` more than once per invocation — one fetch, one report.
- If `hours` is non-numeric or absent, default to `24` without prompting.
