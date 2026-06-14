---
name: amon-sul
description: Use when the user runs /amon-sul <sweep> <tracker> <project> [flags…], where <sweep> is glorfindel (council-stage), aule (forge-stage), or anduin (both stages in sequence — the council→forge pipeline under one watch). An adaptive in-session watcher — it runs one sweep, reads the result, then self-schedules its next ride via ScheduleWakeup, tightening to 5 minutes when work moves and stretching out to 1 hour as the road stays quiet. Honors an optional working-hours window (`--active HH-HH`, or a per-project `working_hours.md` default) so off-hours wakes skip the ride entirely — no sweep forged while the keeper sleeps. Session-bound: the vigil dies when the session closes. Say "stop the vigil" (or stop /amon-sul) to end it.
user_invocable: true
---

# Amon Sûl — The Watch

Amon Sûl, the watchtower of Weathertop, kept the road under its eye through
the long years. So this skill: it keeps one watch over a tracker's tickets,
sending a rider out to sweep, then choosing for itself how long to wait before
sending the next — close watch when work moves, an ever-longer quiet as the road
sleeps, out to an hour.

The rider is yours to name. **Glorfindel** rides the council stage (draft and
refine plans on open tickets); **Aulë** rides the forge stage (open PRs for
tickets whose counsel is approved and awaiting the smith); **Anduin** rides both
in sequence (council then forge, one pass) for those who want the whole pipeline
under one watch. Amon Sûl watches with whichever you summon.

## Ethos

- **Amon Sûl watches; the rider rides; the council still decides.** This skill
  posts nothing of its own. Every comment, verdict, state change, and PR is the
  named sweep's doing. Amon Sûl only chooses *when* to ride next.
- **The cadence answers the road, not the clock.** The longer the road stays
  unchanged, the longer the wait climbs; the moment work stirs, it snaps back to
  a close watch. The watch spends its attention where the work is.
- **The hour is the ceiling, by design.** `ScheduleWakeup` clamps a single wait
  to one hour, and that is where the ladder stops — past it, an in-session watch
  cannot truly sleep, only wake hourly to re-arm, which saves nothing. For
  genuinely rare checks on a long-dead board, reach for a durable cron
  (`0 */6 * * *` and the like) instead — it sleeps where this watch only hops.
- **It is `/loop` with a rubric.** Mechanically this is `/loop` in dynamic mode
  wrapped around one sweep. Its reason to exist is the escalating cadence below —
  a named, consistent back-off ladder so neither watcher nor user re-derives it
  each session.

## Argument parsing

`/amon-sul <sweep> <tracker> <project> [flags…]`

| Token | Meaning |
|---|---|
| `<sweep>` | The rider: `glorfindel` (aliases `council`, `sweep`), `aule` (alias `forge`), or `anduin` (alias `pipeline`) for both stages in sequence. Required — Amon Sûl will not guess. |
| everything after `<sweep>` | Passed to `/<sweep>`, **less Amon Sûl's own tokens** (`--active …`, `::streak=N`), which are parsed off and stripped first. |

The remainder — `<tracker> <project>` and any flags — is handed straight to the
named sweep, whose own argument grammar then governs. Amon Sûl adds no arguments
of its own; it only wraps the sweep in an adaptive schedule and, where bidden,
holds that schedule to the keeper's working hours.

- `glorfindel` grammar: `<tracker> <project> [--filter …] [--dry-run] [--confirm]`.
- `aule` grammar: `<tracker> <project> [--filter …] [--max N] [--ready] [--auto] [--dry-run] [--confirm]`.
- `anduin` grammar: `<tracker> <project> [--filter …] [--max N] [--ready] [--dry-run] [--confirm]` — rides `/glorfindel` then `/aule` in one pass. **The forge runs unattended by default** (`--auto --max 3`); there is no `--auto` to type — pass `--dry-run` or `--confirm` to gate it. The filter should straddle Open *and* the `forth` state (e.g. `--filter "#Unresolved"`), else the forge stage misses council-advanced tickets.

If `<sweep>` is missing or is not one of the three riders, stop and show the usage
line above — do not default to a rider the user did not name.

**The streak token.** A trailing `::streak=N` may appear on the invocation — this
is Amon Sûl's own bookkeeping, written by the watch into its re-arm prompt so the
next ride knows how long the road has stayed quiet (see *Read the road*). Parse
it off the **end** of the arguments, hold the integer (default `0` if absent),
and **strip it** before handing the remainder to the sweep — the sweep must never
see it. The user does not type this; if they do, honour it as the starting count.

**The active-hours flag.** An optional `--active <window>` may appear among the
flags — Amon Sûl's own, never the sweep's. Parse it off, **strip it** before
handing the remainder to the sweep, and let it govern the *working hours* gate
(see *Ride*). The window takes three forms:

- `--active 09-18` — a daytime span (rides only between 09:00 and 18:00 local).
- `--active 22-06` — a span that **wraps midnight** (rides 22:00 through 06:00).
- `--active off` — force always-on, overriding any memory default.

Resolution runs **flag → memory → always-on**: the flag wins when present; absent
it, read the per-project default from `working_hours.md` (keyed by the `<project>`
token, the same one handed to the sweep — read it, do not strip it); absent both,
the watch rides every tick as it always has. The window is read in **local machine
time**, for it is the keeper's sleep it answers to.

## Workflow

### 1. Ride

**The working-hours gate, first.** Resolve the active window (flag → memory →
none, per *The active-hours flag*). If a window is in force, read the current
**local** time — a small `date` call on wake — and test it against the span (a
midnight-wrapping span like `22-06` holds when the hour is ≥ start *or* < end).

- **Now lies outside the window** → **do not ride.** Send no sweep; read no
  tracker; forge nothing. Announce one line — *"off-hours, holding; next look at
  HH:MM."* — leave the streak **frozen** (a skipped ride read no road, so it is
  neither stir nor quiet), and arm the next wake at `min(3600s, seconds until the
  window next opens)`. Re-append `::streak=N` unchanged. Skip steps 2–3 this turn.
- **Now lies inside the window, or no window is in force** → ride, as below.

Parse `::streak=N` (see above), then invoke `/<sweep> <rest>` through the Skill
tool, passing the remaining arguments exactly as received. Let the sweep do its
whole job — listing, the per-ticket machinery, posting, transitions or forging,
and its own aggregate report. Amon Sûl reads the report; it duplicates none of
the work.

### 2. Read the road

From the sweep's aggregate report, decide whether the board **stirred** or stayed
**quiet**. The triggers differ by rider:

| Outcome | Glorfindel trigger | Aulë trigger | Anduin trigger |
|---|---|---|---|
| **Stirring** | Any ticket was `drafted`, `forth`, `forged`, `nay`, `farewell`, or `talked-out` | Any ticket `forged`, **or** qualifiers remain for the next sweep | Anduin's combined report ends in `Anduin — STIRRED` |
| **Quiet** | All tickets `quiet` / `untouched`, or the road lay empty | None forged and no qualifiers remain, or no tickets in scope | Anduin's combined report ends in `Anduin — QUIET` |

Anduin already folds both stages' road-reading into its own verdict line, so for
the `anduin` rider Amon Sûl simply reads that token — no need to re-derive it.

Then set the streak:

- **Stirring** → `streak = 0` (reset — work moved, watch closely).
- **Quiet** → `streak = N + 1` (climb a rung — the road has been still one ride longer).

### 3. Arm the next watch

Find the next wait from the streak ladder, capped at the one-hour ceiling:

| Streak | Next delay |
|---|---|
| 0 (stirring) | 300s (5 min) |
| 1 | 600s (10 min) |
| 2 | 1200s (20 min) |
| 3 | 1800s (30 min) |
| ≥4 | 3600s (1 hr — ceiling) |

- Announce one short line — the rider, whether it stirred or stayed quiet, the
  streak, and the wait (e.g. *"Glorfindel — quiet, streak 4; next sweep in 1 hr."*).
  The turn ends the instant `ScheduleWakeup` returns, so announce first.
- As the **last action of the turn**, call `ScheduleWakeup` with:
  - `delaySeconds`: the delay from the ladder.
  - `reason`: one short sentence — rider, road state, wait.
  - `prompt`: the original invocation verbatim, with the streak token
    re-appended — `/amon-sul <sweep> <tracker> <project> [flags…] ::streak=<streak>`.

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
- **Watching with Aulë carries real blast radius.** A watch is unattended by
  nature, yet Aulë opens PRs and posts `[GWAITH]`. Amon Sûl injects no flags, so
  the user chooses deliberately:
  - Without `--auto`, Aulë halts each ride at its outer confirmation (and the Jira
    post-safety prompt) — fine only while the user is present to answer.
  - With `--auto`, Aulë forges unattended up to its `--max` cap (default 3) per
    ride. The cap is the only brake; set it with intent. Prefer a `--dry-run`
    pass first to see what *would* forge before arming the real thing.
  - The **`anduin`** rider forges unattended **by default** — its second stage
    *is* Aulë, and Anduin gives Aulë `--auto --max 3` unless gated. So
    `/amon-sul anduin youtrack URD --filter "#Unresolved"` opens PRs every tick the
    pipeline stirs, with no `--auto` in the line to signal it. The brakes are
    `--dry-run` (forge nothing) and `--confirm` (prompt per PR); prefer a
    `--dry-run` watch first to see what would forge.
- **The watch holds outside its keeper's hours.** When a window is in force
  (`--active`, or a `working_hours.md` default), an off-hours wake skips the ride
  whole — no sweep, no forge, no tracker write — and only re-arms for the next
  open. The streak freezes across the dark; it neither climbs nor resets, for no
  road was read. This is the brake against PRs forged at 3 a.m. under `--auto`.
  Note the 1-hour ceiling still bites: a long night is *hopped*, not slept — each
  hop a bare clock-check. For a truly silent night, reach for a durable cron.
- **One watch per invocation.** Re-running `/amon-sul` with the same rider and
  args while a watch is already armed stacks a second wake-up. Stop the first if
  you mean to re-pace; do not double-arm. Two *different* riders (a Glorfindel
  watch and an Aulë watch) are distinct watches and may run together — that is how
  one pipelines council → forge across two cadences.
- **The streak answers the recent past only.** Each ride re-reads the road and
  re-chooses; a long-quiet board that finally stirs resets to a 5-minute watch on
  the very next ride, and a busy board that falls silent climbs the ladder one
  rung per quiet ride.
- **Session-bound.** The watch lives only in this session. When it closes, the
  vigil ends — there is no durable record. Say so if the user expects otherwise.
