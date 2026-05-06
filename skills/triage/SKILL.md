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

Two buckets only — **Worth a look** and **Routine**. Classify in two passes — user overrides first, then static rules.

**Pass 1 — user overrides.** If `~/.skadi/outlook/classify.json` exists, walk its rules. Schema:

```json
{
  "demote_to_routine": [{"from": "<addr>", "subject": "<substr>"}, ...],
  "promote_to_worth":  [{"from": "<addr>", "subject": "<substr>"}, ...]
}
```

`from` is required and matched case-insensitively (exact equality); `subject` is optional substring match (case-insensitive); when a rule has no `subject`, it matches any subject from that sender. Promote wins over demote when both match.

For each message:

- If a `promote_to_worth` rule matches, classify as **Worth a look** and skip pass 2.
- Else if a `demote_to_routine` rule matches, classify as **Routine** and skip pass 2.
- Else fall through to pass 2.

Ad-hoc verification of the verdict for a single message: `~/.claude/hooks/outlook-classify.sh "<from>" "<subject>"` prints `worth`, `routine`, or `default`.

**Pass 2 — static rules.** Mark a message **Worth a look** when *any* of these hold:

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

After the report, render up to two offers — one per pending action, on its own line.

**Worth a look offer** (when M > 0): name the most important item, paste its `webLink` on its own line, then ask `open · demote (subject) · demote (sender) · skip?`. One verb per yes.

- **open** — the user opens the link by hand; the skill does nothing further.
- **demote (subject)** — append `{"from": "<sender>", "subject": "<subject>"}` to `~/.skadi/outlook/classify.json`'s `demote_to_routine` array. Future mail with this subject from this sender classifies as Routine. Create the file (mode 600) if absent; preserve other rules.
- **demote (sender)** — append `{"from": "<sender>"}` (no subject) to `demote_to_routine`. All future mail from this sender classifies as Routine.
- **skip** — do nothing.

**Routine offer** (when N - M > 0): ask `mark read · move to folders · skip?`. One verb per yes; to do both, two yeses.

- **mark read** — pipe each routine message's `id` to `~/.claude/hooks/outlook-mark-read.sh`, one per line. The hook prints `read: <id>` per success and `failed: <id> <code>` on stderr per failure. Render a one-line tally of marked vs failed.
- **move to folders** — for each sub-category present in the Routine batch:
  1. Read `~/.skadi/outlook/folders.json` — a `{ "<sub-category>": "<folder-id>", ... }` map. If the sub-category has an entry, use it.
  2. If missing, run `~/.claude/hooks/outlook-folders.sh` to list folders, present them with their `displayName`, and ask the user to pick one. On answer, append the choice to the map and persist it (create the file if absent, with mode 600).
  3. Pipe the sub-category's IDs to `~/.claude/hooks/outlook-move.sh <folder-id>`, one per line.

  Render a one-line tally per sub-category: `<sub-category> → <folder> (M moved, K failed)`. If a sub-category has no mapping and the user declines to set one, leave those mails in place — the rest still move.
- **skip** — do nothing.

If both M == 0 and N == 0, the inbox is quiet — render the §3 quiet-inbox line and stop.

## Rules

- Never reveal the body content of a message in the report — the subject and sender are enough. The user can open the `webLink` if curious.
- Never bulk-archive or mark-as-read on the user's behalf without an explicit yes for that batch.
- Do not call `outlook-fetch.sh` more than once per invocation — one fetch, one report.
- If `hours` is non-numeric or absent, default to `24` without prompting.
