---
name: minuial
description: Use when the user runs /minuial. The morning-start ritual — boots (or reuses) the standing Henneth window, serves the situation board, then refreshes it (tickets + metis growth), printing both URLs. Read-only; the one call that lights every dashboard before the day's work begins.
user_invocable: true
---

# Minuial — the Dawn-Twilight

In the reckoning of the Elves, Minuial named the hour before sunrise — the first
stirring of light before the day proper. So this skill: the one call that lights
every window before the day's work begins.

## Workflow

Three skills, one after another, no gate between them — this composes existing
read-only skills; there is nothing here to weigh or branch on.

### 1. Henneth

Invoke `/henneth` through the Skill tool. Boots the standing artifact window if it
is not already running, reuses it if it is.

### 2. Board — serve

Invoke `/board` through the Skill tool (bare, no arguments). Lays the board page,
boots or reuses its server, prints the URL.

### 3. Board — refresh

Invoke `/board refresh` through the Skill tool. Re-fetches every seated ticket and
the metis growth numbers. `board.sh refresh` already runs the growth hook
(`board-growth.sh` → `appgrowth.py`, the same query `/growth` runs standalone) as
part of its own sweep — a separate `/growth` call would only repeat the same
BigQuery pull, so Minuial does not make one.

### 4. Report

Print both URLs — Henneth's window and the Board's — and let `/board refresh`'s
own output stand for what it pulled. Nothing further to report; nothing was
written, forged, or posted.

## Notes

- **Read-only.** Every step it composes is itself read-only — Henneth boots a
  server, Board serves and refreshes from Jira/YouTrack and BigQuery. Minuial
  opens no PR, posts no comment, changes no ticket.
- **No seated tickets is not an error.** If the board carries no ticket channels
  yet, `/board refresh`'s ticket loop is simply empty — the growth pull still
  runs. Seat one first with `/board add <KEY> [--active]` to have it on the
  morning board.
