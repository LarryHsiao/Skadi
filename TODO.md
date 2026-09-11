# TODO

One item stands open. Everything else in flight has landed.

---

## Run one real `/feanor` pass against a Vilya-held dev server

**Branch:** `claude/latest-todo-plan-gvm0am` (pushed; `git pull` and it is there)
**Plan:** `docs/plans/vilya-local-server-daemon.md` — step 5, standing at `[~]`
**Blocked by:** no reachable headless browser in the session that wrote it

### What is owed

The Vilya plan's fifth step replaced `/feanor`'s "wait a few seconds and
re-shoot" with a real gate: `vilya ready` decides whether the next screenshot is
worth taking. The prose is written and shipped. What has never run is the thing
the step's own verify line asks for — **one real `/feanor` pass** against a dev
server held by Vilya, whose rebuild outlasts the old fixed settle.

### Why it did not run

The session that wrote it had no headless browser it was allowed to reach. The
only one on that machine sat under `/opt/pw-browsers`, outside `dir-guard.sh`'s
permitted paths, and routing around that guard is not something this repo
permits. `hooks/feanor-shot.sh` exits 3 — "no headless browser found" — there.

On a machine with Chrome, Chromium or Edge installed normally, the hook finds it
on `PATH` and none of this applies.

### How to run it

1. Raise a real dev server under Vilya — a Vite or Zola project, anything whose
   rebuild takes more than the 2000ms `FEANOR_SETTLE_MS` default:

       ~/.claude/hooks/vilya.sh start --name web \
         --ready-pattern 'ready in' -- npm run dev

   Take the ready pattern from the server's own first run, not from this file.
   Keep it short — it is an extended regular expression, so a whole banner line
   defeats itself on its own parentheses.

2. Confirm the gate answers before involving `/feanor` at all:

       ~/.claude/hooks/vilya.sh ready --name web --timeout 60

3. Run `/feanor <served-url> <spec.png>` and watch the loop follow
   `skills/feanor/SKILL.md`'s step 5 — the Web bullet, "Held by Vilya". What is
   being tested is whether an agent reading that prose mid-loop actually gates
   its shots on the exit code, and whether the shot it takes after a `0` shows
   the mended page rather than the stale one.

### What to watch for

- **The sharp case.** A server whose rebuild reaches the browser *without
  changing the served document* — Vite's HMR patches an already-loaded page over
  a socket — is the one a byte comparison cannot see and a real render can. If
  `/feanor` shoots a fresh headless browser each pass this should be fine, since
  the fresh load fetches the updated modules; confirm it rather than assume it.
- **The branches nobody has walked.** Only the `0` path has been exercised
  outside unit tests. Try to see a `7` (stop the rebuild from succeeding) and a
  `6` (start a server with no `--ready-pattern`) and check the prose tells you
  what to do in each.

### How to close it

- Tick step 5 in `docs/plans/vilya-local-server-daemon.md` from `[~]` to `[x]`
  and stamp the closing commit's sha into its `<!-- sha: ... -->` marker.
- Delete the **What the fifth step still owes** section from that plan.
- Delete this file.

If the real run turns up something the prose gets wrong, mend
`skills/feanor/SKILL.md` first and re-run before ticking anything.

---

## Already done, for orientation

| Step | State | Commit |
|---|---|---|
| Hold a process end to end | done | `e89e5d4` |
| Register on the statusline | done | `c203304` |
| Give it a real completion signal | done | `e7393b4` |
| Reach it from chat | done | `3334a44` |
| Close feanor's gap | **prose landed, verification owed** | `ef95a5d` |

The hook is `hooks/vilya.sh`, its suite `hooks/vilya.test.sh` (50 checks, green),
and its skill `skills/vilya/SKILL.md`. Read the skill before the hook — it
carries the judgment, the hook carries the mechanism.

**One caveat that is not this task but is worth knowing:** `shellcheck` was never
installed on the machine that wrote all of this, so `hooks/lint.sh` has not run
over `hooks/vilya.sh` even once. If the machine you pick this up on has it,
running it is cheap and would close a gap nobody has looked through.
