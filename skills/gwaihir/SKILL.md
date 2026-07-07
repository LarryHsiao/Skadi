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

<!-- filled by later tasks -->

## Read-only guarantee

<!-- filled by Task 4 -->

## Rules

<!-- filled by Task 4 -->
