# Vilya — a standing holder for protocol-less local servers

Narya holds a Flutter app alive so any later turn, session, or skill can poke
it. Nothing holds a *web* dev server the same way, and two shipped skills
already carry the hole where that belongs.

`/feanor`'s render→compare→mend loop shows the gap plainly
(`skills/feanor/SKILL.md:565-576`). On the Flutter path it drives
`flutter-daemon.sh reload` and reads the exit code — "`0` shoot, anything else
do not, since a screenshot of a stale binary reads as a mend that did nothing."
On the web path it has only: *"a dev server hot-reloads (a few seconds — if the
next shot still shows the pre-edit state, wait briefly and re-shoot)."* That is
a retry by eye, not a synchronization primitive, and it exists because nothing
owns the web server, so nothing can read its log to know when the rebuild
landed. `universal.md`'s *Resource Lifecycle* names this failure directly: where
completion is knowable, signal it directly rather than racing a clock against
work of unknown duration. Owning the process is what makes the log reachable,
and the log is where the completion signal lives.

Who wants this:

| # | Scenario | Today |
|---|---|---|
| 1 | `/feanor` web path | Needs a server it cannot start; waits by eye, not by signal |
| 2 | `/manwe` web path | Needs a served URL it cannot start — it "never launches a browser tab or a device itself" |
| 3 | Zola blog preview | Started by hand; invisible to the statusline |
| 4 | React/Vite dev server | Same, and `docs/style/react.md` says React work here is real |

## Why not widen narya

Narya's heaviest machinery — the `tail -f cmds | flutter run --machine` pipe,
the JSON protocol reader, request ids, `app.restart`, appId resolution — exists
to solve one problem its own header explains at length: `flutter run` reads
keystrokes from a TTY, so a backgrounded one hits EOF and dies at once. Zola and
Vite do not have that problem. They read nothing from stdin, speak no protocol,
and need no hot-reload channel — they watch their own files. `nohup <cmd> >log
2>&1 &` with a pid file holds them.

Widening narya would route a protocol-less server through machinery built for a
problem it does not have, and turn `reload`, `restart`, and the whole
command-pipe half of the file into "only when this is a Flutter daemon" — a
boolean threaded through 616 lines that today read as one coherent thing. Vilya
is smaller than narya, not a copy of it.

## Decisions taken

- **Keyed on (project, name).** Narya keys on (project, device); one project may
  hold several servers at once — a web dev server and an API mock — so the name
  is the slot.
- **No `reload` / `restart` verbs.** A protocol-less server either watches its
  own files or wants a real bounce, and `stop` + `start` already is that bounce.
- **URL resolution: explicit wins.** `--url` at `start` is authoritative; absent
  it, grep the log for the first `http(s)://` (zola prints "Web server is
  available at…", Vite prints "Local: …"), the same technique narya uses for the
  DevTools banner. Neither found means no registration, and `start` still
  succeeds.
- **Label defaults to the name.** `--label` overrides it for the statusline row.
- **The lifecycle scaffolding repeats narya's** — and by more than the ~40
  lines first estimated. Written out, the near-verbatim surface is
  `resolve_project`, `project_dir`, the name/device slug, `meta_get` /
  `meta_set` (byte-identical), the require / alive guards, `last_words`, and
  `reap`. Accepted still, but as a judgment call rather than a rule
  application: `universal.md` says lift a shared shape on the third recurrence,
  and narya plus Vilya is two — yet that rule's own examples are small ones ("a
  condition, a method body, a transform"), so forty lines sits at the edge of
  what it was written for. The case for waiting is that the two files' spines
  differ (one holds a protocol, one holds a plain process), and an abstraction
  drawn now would be shaped by a single sibling. Revisit at the third holder, or
  sooner if the duplicated part starts drifting between the two.
- **Every verb takes an explicit name in the first cut.** Narya's fan-out across
  unqualified slots is deferred until the want proves real.

## Out of scope

- **Migrating Board / Henneth / Galadriel** off their hardcoded statusline
  stanzas onto the registry. They boot themselves and already render; churn
  without gain today. Worth revisiting only if a fourth built-in appears.
- **Fan-out across a project's servers** for unqualified `status` / `stop`, per
  the decision above.
- **Booting browsers or navigating.** Vilya raises a server and nothing else,
  the same boundary narya keeps for devices.

## Risks

- **A crash slower than the settle window reads as a success.** `start` proves
  liveness by pausing `SPAWN_SETTLE_SECONDS` and asking whether the process is
  still there. A server whose failure surfaces after that budget — a slow
  import, a bind error raised late — is reported `started`, and only the next
  `status` corrects it. This is the fixed delay `universal.md` warns against,
  standing in for a synchronization primitive; it is carried knowingly until the
  `ready` verb's log pattern replaces it, and the lie it can tell is at least
  short-lived and self-correcting on the next question asked.
- **Ready patterns are per-server.** Vite, webpack, and zola each announce
  differently, so the pattern must be configured per slot. Absent one, the
  fallback is the fixed settle in use today — no better, but no worse, and every
  server taught a pattern moves from guessing to knowing.
- **A server that daemonizes itself** (double-forks and returns) would leave the
  pid file naming a process that has already exited. Most dev servers stay in
  the foreground; a self-daemonizing one is out of scope rather than silently
  mishandled, and `status` should say so plainly when the pid is dead but the
  port still answers.
- **Windows / Git Bash.** Narya's header records that MSYS's `bin/flutter` execs
  through `cmd.exe`, which is why it uses a real shell pipe rather than a fifo.
  Vilya needs no fifo at all, but `nohup`'s behaviour there is unproven and
  should be checked before the hook is trusted on that platform.

## Steps

- [x] **Hold a process end to end.** `hooks/vilya.sh` with `start` / `status` / `stop` / `log`; state under `$SKADI_VILYA_ROOT` (default `~/.skadi/vilya`) as `<project-slug>/<name>/` holding `pid`, `log`, `meta`; spawned with `nohup`, no pipe apparatus. **Verify:** `hooks/vilya.test.sh` — start a `python3 -m http.server` on a free port, assert the pid lives and the port answers, `stop`, assert both are gone; plus argument handling and the no-such-server exit codes. <!-- sha: e89e5d4 -->
- [x] **Register on the statusline.** On a successful `start`, resolve the URL per the decision above and call `window-register.sh register vilya-<project>-<name> <url> <label>`; unregister on the teardown path, the single point every stop passes through — narya's `reap()` pattern. **Verify:** extend `vilya.test.sh` — the registry file appears with the right url and label after `start` and is gone after `stop`; a server with no URL in its log and no `--url` still starts cleanly and registers nothing. <!-- sha: c203304 -->
- [x] **Give it a real completion signal.** `vilya ready <name> [--since <offset>] [--timeout <s>]` — watch the log from a byte offset for a per-server ready pattern (`--ready-pattern` at `start`, kept in `meta`), exit 0 on match and non-zero on timeout: the shape of narya's `await_result`. **Verify:** a test whose stub server prints its ready line after a delay — assert `ready` blocks, then exits 0; assert it exits non-zero when the pattern never comes. <!-- sha: e7393b4 -->
- [~] **Reach it from chat.** `skills/vilya/SKILL.md` — the full verb table (every verb from the three steps above, so the table is written once rather than re-edited), and the judgment for when to reach for Vilya over narya or over a plain background Bash call. Add `Bash(~/.claude/hooks/vilya.sh:*)` to `settings.json`. **Verify:** `/install` sweeps every root clean, and `/vilya status <name>` answers from a fresh session.
- [ ] **Close feanor's gap.** Replace `skills/feanor/SKILL.md`'s "wait briefly and re-shoot" with: when the target is served by a Vilya-held server, call `vilya ready` and let its exit code gate the next shot, exactly as the Flutter path uses `flutter-daemon.sh reload`. Keep the fixed-settle fallback for a server Vilya does not hold. **Verify:** partly by eye — the two paths must read symmetrically — plus one real feanor run against a Vilya-held dev server whose rebuild outlasts the old fixed settle.
