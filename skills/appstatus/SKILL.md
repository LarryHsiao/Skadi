---
name: appstatus
description: Use when the user runs /appstatus. Prints a cross-app Firebase health snapshot — Firestore reads/writes, Cloud Functions calls and errors, and Storage — for the personal account's Firebase apps over the last 24h, in one table. Read-only; Cloud Monitoring reads sit in the free tier, so it costs nothing.
user_invocable: true
---

# App Status

A one-table glance at your Firebase apps' health over the last 24 hours — usage
and error signals pulled from Cloud Monitoring, read-only and free.

## Run

    ~/.claude/hooks/appstatus.py

Print the table it returns. Each row is a Firebase app; the columns are
Firestore reads/writes, Cloud Functions calls, Cloud Functions errors (flagged
with `!` when above zero), and Storage in GB, summed over the last 24h.

## Account

The script is pinned to the account that owns the apps via `gcloud`, so it never
falls back to a different active login. If it reports no access token, that
account needs a login:

    gcloud auth login <account>

Override the account with the `APPSTATUS_ACCOUNT` environment variable.

## Notes

- **Read-only, no cost.** Monitoring reads sit inside the free tier; a snapshot
  makes a few dozen API calls, nowhere near the threshold.
- **Zeros are real.** An app with no users reads zero across the activity
  columns — accurate, not a fault. Storage shows bytes at rest even when traffic
  is nil.
- **Cost is not here.** Billing/$ figures need billing-viewer access the CLI
  lacks; use the GCP Billing Reports console for cost.
