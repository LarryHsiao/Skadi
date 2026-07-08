---
name: amon-sul
description: Use when the user runs /amon-sul <sweep> <tracker> <project> [flags…], where <sweep> is glorfindel (council-stage), aule (forge-stage), anduin (both stages in sequence — the council→forge pipeline under one watch), moria (mend-stage — sweep your repos for unaddressed PR/MR comments and answer them with code; takes no tracker/project), or rhovanion (the council→forge pipeline across every project in pipeline_projects.md, each gated by a cheap per-project movement probe; takes no tracker/project). An adaptive in-session watcher — it runs one sweep, reads the result, then self-schedules its next ride via ScheduleWakeup, tightening to 5 minutes when work moves and stretching out to 1 hour as the road stays quiet. Honors an optional working-hours window (`--active HH-HH`, or a per-project `working_hours.md` default) so off-hours wakes skip the ride entirely — no sweep forged while the keeper sleeps. Session-bound: the vigil dies when the session closes. Say "stop the vigil" (or stop /amon-sul) to end it.
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
under one watch; **Moria** rides the mend stage — sweeping your repos for unaddressed
PR/MR comments and answering them with code — and carries no tracker or project, only
its own flags; **Rhovanion** rides the whole watershed — the council→forge pipeline
across every project in `pipeline_projects.md`, each ride gated behind a cheap
movement probe so still projects cost a single query — and likewise carries no tracker
or project. Amon Sûl watches with whichever you summon.

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
| `<sweep>` | The rider: `glorfindel` (aliases `council`, `sweep`), `aule` (alias `forge`), `anduin` (alias `pipeline`) for both stages in sequence, `moria` (alias `mend`) to sweep your repos for unaddressed PR/MR comments, or `rhovanion` (alias `watershed`) for the council→forge pipeline across every project in `pipeline_projects.md`. Required — Amon Sûl will not guess. |
| everything after `<sweep>` | Passed to `/<sweep>`, **less Amon Sûl's own tokens** (`--active …`, `::streak=N`), which are parsed off and stripped first. |

The remainder — `<tracker> <project>` and any flags — is handed straight to the
named sweep, whose own argument grammar then governs. Amon Sûl adds no arguments
of its own; it only wraps the sweep in an adaptive schedule and, where bidden,
holds that schedule to the keeper's working hours.

**Moria and Rhovanion are the exceptions to the `<tracker> <project>` shape.** Each
reads its own list file, so neither takes a tracker or project. Moria's form is
`/amon-sul moria [--scope mine|all] [--dry-run] [--auto] [--confirm]` — it reads the
repos from `mend_repos.md`. Rhovanion's is `/amon-sul rhovanion [--dry-run] [--confirm]`
— it reads the projects from `pipeline_projects.md`. Everything after the rider name
(less Amon Sûl's own `--active …` / `::streak=N`) is handed straight to that sweep.

- `glorfindel` grammar: `<tracker> <project> [--filter …] [--dry-run] [--confirm]`.
- `aule` grammar: `<tracker> <project> [--filter …] [--max N] [--ready] [--auto] [--dry-run] [--confirm]`.
- `anduin` grammar: `<tracker> <project> [--filter …] [--max N] [--ready] [--dry-run] [--confirm]` — rides `/glorfindel` then `/aule` in one pass. **The forge runs unattended by default** (`--auto --max 3`); there is no `--auto` to type — pass `--dry-run` or `--confirm` to gate it. The filter should straddle Open *and* the `forth` state (e.g. `--filter "#Unresolved"`), else the forge stage misses council-advanced tickets.
- `moria` grammar: `[--scope mine|all] [--dry-run] [--auto] [--confirm]` — no tracker/project; sweeps every repo in `mend_repos.md`. **Mends unattended only with `--auto`** — without it, Moria halts at its outer gate each ride and the watch freezes (see the blast-radius rule). Prefer a `--dry-run` watch first to see what would be mended.
- `rhovanion` grammar: `[--dry-run] [--confirm]` — no tracker/project; rides `/anduin` across every project in `pipeline_projects.md`, gated per project by a cheap movement probe. **The forge runs unattended by default** (each ride's `/anduin` forges unless gated); there is no `--auto` to type — pass `--dry-run` or `--confirm` to gate it. Prefer a `--dry-run` watch first to see what would forge.

If `<sweep>` is missing or is not one of the five riders, stop and show the usage
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

For the **`moria`** and **`rhovanion`** riders, which carry no `<project>` token, the
memory default has no project to key on — so only an explicit `--active` window governs;
absent it, the watch is always-on.

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

| Outcome | Glorfindel trigger | Aulë trigger |
|---|---|---|
| **Stirring** | Any ticket read anything other than `quiet` / `untouched` — `drafted`, `answered`, `dry-run`, `forth`, `forged`, `nay`, `farewell`, `talked-out`, `skipped`, or `error` all count | Any ticket read `forged`, `closed`, `aborted`, `answered`, `dry-run`, or `error` (an `aborted` ticket is retryable work still waiting, not silence), **or** qualifiers remain for the next sweep |
| **Quiet** | Every ticket read `quiet` / `untouched`, or the road lay empty | None of `forged`, `closed`, `aborted`, `answered`, `dry-run`, or `error`, and no qualifiers remain, or no tickets in scope |

This mirrors `/anduin`'s own STIRRED/QUIET partition (see `anduin/SKILL.md`) —
"anything but the quiescent outcomes" — so a direct `/amon-sul aule …` or
`/amon-sul glorfindel …` ride classifies the same error or aborted-ticket case the
same way an `/anduin`-wrapped ride would.

Anduin, Moria, and Rhovanion each fold their road-reading into their own verdict line,
so for those riders Amon Sûl simply reads the token — `Anduin — STIRRED`/`QUIET`,
`Moria — STIRRED`/`QUIET` (stirred when any repo's sweep landed a commit), or
`Rhovanion — STIRRED`/`QUIET` (stirred when any ridden project's Anduin stirred) — no
need to re-derive it. All three are absent from the table above for that reason: their
verdict line *is* the trigger.

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

- **Mark the board** — when a situation board is in use (`~/.skadi/board/` exists),
  record this ride's verdict so the sweep band feeds itself:
  `~/.claude/hooks/board.sh sweep <rider> <stirred|quiet> "<brief detail>"` — where
  `<rider>` is the sweep name (`glorfindel`, `aule`, `anduin`, `moria`, `rhovanion`),
  the verdict maps STIRRED → `stirred` and QUIET → `quiet`, and the detail is a short
  phrase from the ride (e.g. `"3 planned · streak 0"` or `"quiet · streak 4"`). Skip
  silently when no board exists — the watch never forces one into being, and a failed
  record never derails the ride.
- Announce one short line — the rider, whether it stirred or stayed quiet, the
  streak, and the wait (e.g. *"Glorfindel — quiet, streak 4; next sweep in 1 hr."*).
  The turn ends the instant `ScheduleWakeup` returns, so announce first.
- As the **last action of the turn**, call `ScheduleWakeup` with:
  - `delaySeconds`: the delay from the ladder.
  - `reason`: one short sentence — rider, road state, wait.
  - `prompt`: the original invocation verbatim, with the streak token
    re-appended — `/amon-sul <sweep> <tracker> <project> [flags…] ::streak=<streak>`
    (for `moria` and `rhovanion`, `/amon-sul <sweep> [flags…] ::streak=<streak>` — no
    tracker/project).

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
- **Watching with Moria carries its own blast radius.** Moria mends unattended only
  with `--auto` — without it the outer gate freezes the watch each ride, waiting for a
  word no one is there to give. With `--auto`, Moria answers unaddressed comments
  across every repo in `mend_repos.md` with real commits, every tick a comment stands;
  `--scope all` widens that to PRs you did not author. The brakes are `--dry-run`
  (write nothing) and `--scope mine` (your PRs only); prefer a `--dry-run` watch first
  to see what would be mended.
- **Watching with Rhovanion forges unattended by default — across many projects.**
  Each ride dispatches `/anduin` per *moved* project, and `/anduin` forges unattended
  unless gated. So `/amon-sul rhovanion` opens PRs in every project that stirs, every
  tick it stirs, with no `--auto` in the line to signal it — the same default as the
  `anduin` rider, multiplied across `pipeline_projects.md`. The cursor gate bounds the
  *cost* (still projects cost only a probe) but not the *blast radius* of a moving one.
  The brakes are `--dry-run` (forge nothing) and `--confirm` (prompt per PR); prefer a
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
