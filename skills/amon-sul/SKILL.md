---
name: amon-sul
description: Use when the user runs /amon-sul <sweep> <tracker> <project> [flags…], where <sweep> is glorfindel (council-stage) or aule (forge-stage). An adaptive in-session watcher — it runs one sweep, reads the result, then self-schedules its next ride via ScheduleWakeup, tightening to 5 minutes when work moves and stretching out to 6 hours as the road stays quiet. Session-bound: the vigil dies when the session closes. Say "stop the vigil" (or stop /amon-sul) to end it.
user_invocable: true
---

# Amon Sûl — The Watch

Amon Sûl, the watchtower of Weathertop, kept the road under its eye through
the long years. So this skill: it keeps one watch over a tracker's tickets,
sending a rider out to sweep, then choosing for itself how long to wait before
sending the next — close watch when work moves, an ever-longer quiet as the road
sleeps, out to a six-hour span.

The rider is yours to name. **Glorfindel** rides the council stage (draft and
refine plans on open tickets); **Aulë** rides the forge stage (open PRs for
tickets whose counsel is approved and awaiting the smith). Amon Sûl watches with
whichever you summon.

## Ethos

- **Amon Sûl watches; the rider rides; the council still decides.** This skill
  posts nothing of its own. Every comment, verdict, state change, and PR is the
  named sweep's doing. Amon Sûl only chooses *when* to ride next.
- **The cadence answers the road, not the clock.** The longer the road stays
  unchanged, the longer the wait climbs; the moment work stirs, it snaps back to
  a close watch. The watch spends its attention where the work is.
- **It is `/loop` with a rubric.** Mechanically this is `/loop` in dynamic mode
  wrapped around one sweep. Its reason to exist is the escalating cadence below —
  a named, consistent back-off ladder so neither watcher nor user re-derives it
  each session. For a *fixed* interval, reach for `/loop <interval> /<sweep> …`
  instead; to survive a session restart, no in-session watcher can — use a
  durable cron and accept the fixed clock.

## Argument parsing

`/amon-sul <sweep> <tracker> <project> [flags…]`

| Token | Meaning |
|---|---|
| `<sweep>` | The rider: `glorfindel` (aliases `council`, `sweep`) or `aule` (alias `forge`). Required — Amon Sûl will not guess. |
| everything after `<sweep>` | Passed **verbatim** to `/<sweep>`. |

The remainder — `<tracker> <project>` and any flags — is handed straight to the
named sweep, whose own argument grammar then governs. Amon Sûl adds no arguments
of its own; it only wraps the sweep in an adaptive schedule.

- `glorfindel` grammar: `<tracker> <project> [--filter …] [--dry-run] [--confirm]`.
- `aule` grammar: `<tracker> <project> [--filter …] [--max N] [--ready] [--auto] [--dry-run] [--confirm]`.

If `<sweep>` is missing or is not one of the two riders, stop and show the usage
line above — do not default to a rider the user did not name.

**The bookkeeping tokens.** Two trailing tokens may appear — `::streak=N` and
`::sleep=S` — written by the watch into its own re-arm prompt so the next wake
knows how long the road has stayed quiet (`streak`) and whether it is mid-way
through a multi-hour wait (`sleep`, in seconds remaining). Parse both off the
**end** of the arguments, hold the integers (default `0` each if absent), and
**strip them** before handing the remainder to the sweep — the sweep must never
see them. The user does not type these; if they do, honour them as the starting
state.

## Workflow

### 1. Hop or ride

Parse `::streak=N` and `::sleep=S` (see above).

- **If `S > 0`** — the watch is mid-way through a long wait the 1-hour clamp could
  not serve in one sleep. This wake is a **hop**, not a sweep: do *not* run the
  rider. Skip straight to *Arm* (step 3) and serve the next chunk.
- **If `S == 0`** — it is time to act. Invoke `/<sweep> <rest>` through the Skill
  tool, passing the remaining arguments exactly as received. Let the sweep do its
  whole job — listing, the per-ticket machinery, posting, transitions or forging,
  and its own aggregate report. Amon Sûl reads the report; it duplicates none of
  the work. Then continue to *Read the road* (step 2).

### 2. Read the road

(Only on a real ride — skip when hopping.) From the sweep's aggregate report,
decide whether the board **stirred** or stayed **quiet**. The triggers differ by
rider:

| Outcome | Glorfindel trigger | Aulë trigger |
|---|---|---|
| **Stirring** | Any ticket was `drafted`, `forth`, `forged`, `nay`, `farewell`, or `talked-out` | Any ticket `forged`, **or** qualifiers remain for the next sweep |
| **Quiet** | All tickets `quiet` / `untouched`, or the road lay empty | None forged and no qualifiers remain, or no tickets in scope |

Then set the streak:

- **Stirring** → `streak = 0` (reset — work moved, watch closely).
- **Quiet** → `streak = N + 1` (climb a rung — the road has been still one ride longer).

### 3. Arm the next watch

First, find the **target interval** from the streak ladder:

| Streak | Target | Streak | Target |
|---|---|---|---|
| 0 (stirring) | 300s (5 min) | 4 | 3600s (1 hr) |
| 1 | 600s (10 min) | 5 | 7200s (2 hr) |
| 2 | 1200s (20 min) | 6 | 10800s (3 hr) |
| 3 | 1800s (30 min) | ≥7 | 21600s (6 hr — ceiling) |

On a **hop** (step 1, `S > 0`), the target is the remaining `S` instead — keep the
streak unchanged.

Then serve it within the 1-hour clamp:

- Let `remaining` = the target (on a real ride) or `S` (on a hop).
- `chunk = min(remaining, 3600)`.
- `next_sleep = remaining - chunk`.
- Announce one short line — the rider, whether it stirred or stayed quiet, the
  streak, and the *effective* wait (e.g. *"Glorfindel — quiet, streak 5; next
  real sweep in 2 hr (served as 2 hourly hops)."*). The turn ends the instant
  `ScheduleWakeup` returns, so announce first.
- As the **last action of the turn**, call `ScheduleWakeup` with:
  - `delaySeconds`: `chunk`.
  - `reason`: one short sentence — rider, road state, effective wait.
  - `prompt`: the original invocation verbatim, with the bookkeeping tokens
    re-appended — `/amon-sul <sweep> <tracker> <project> [flags…] ::streak=<streak> ::sleep=<next_sleep>`.

When `next_sleep` is `0`, the next wake is a real ride; when it is positive, the
next wake is another hop that serves the following chunk.

### 4. Ending the watch

Stop — omit the `ScheduleWakeup` call — when:

- The user says to stop the vigil (or stop `/amon-sul`). They are present; no
  notification is needed.
- A hard error recurs that no further ride will mend (credentials gone, the
  tracker unreachable across two consecutive rides). Name the error plainly and
  stop. Before stopping on an error the user has not seen, send a one-line
  outcome via `PushNotification` — the user may be away.

## Rules

- **Amon Sûl never posts or forges of its own.** It owns only the schedule. All
  tracker writes and PRs are the named sweep's, gated exactly as that sweep gates
  them — `--dry-run`, `--confirm`, `--auto`, `--max` pass straight through.
- **The long tiers hop, they do not slumber.** The 1-hour `ScheduleWakeup` clamp
  means a 2-, 3-, or 6-hour wait is served as that many hourly wakes — each a
  cheap re-arm that runs no sweep. The saving of a long tier is the *sweep work*
  skipped (hooks, subagents, posts), not the per-wake cost; the watch still stirs
  hourly to re-arm. If even that is too much, stop the watch and re-run it by hand.
- **Watching with Aulë carries real blast radius.** A watch is unattended by
  nature, yet Aulë opens PRs and posts `[GWAITH]`. Amon Sûl injects no flags, so
  the user chooses deliberately:
  - Without `--auto`, Aulë halts each ride at its outer confirmation (and the Jira
    post-safety prompt) — fine only while the user is present to answer.
  - With `--auto`, Aulë forges unattended up to its `--max` cap (default 3) per
    ride. The cap is the only brake; set it with intent. Prefer a `--dry-run`
    pass first to see what *would* forge before arming the real thing.
- **One watch per invocation.** Re-running `/amon-sul` with the same rider and
  args while a watch is already armed stacks a second wake-up. Stop the first if
  you mean to re-pace; do not double-arm. Two *different* riders (a Glorfindel
  watch and an Aulë watch) are distinct watches and may run together — that is how
  one pipelines council → forge across two cadences.
- **The streak answers the recent past only.** Each real ride re-reads the road
  and re-chooses; a long-quiet board that finally stirs resets to a 5-minute watch
  on the very next ride, and a busy board that falls silent climbs the ladder one
  rung per quiet ride.
- **Session-bound.** The watch lives only in this session. When it closes, the
  vigil ends — there is no durable record. Say so if the user expects otherwise.
