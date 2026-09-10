#!/usr/bin/env bash
# vilya.sh — a standing holder for a protocol-less local server, so any later
# turn, session, or skill can find the thing still running.
#
# WHY NOT WIDEN NARYA
# flutter-daemon.sh carries a `tail -f cmds | flutter run --machine` pipe, a
# JSON protocol reader, request ids and appId resolution — all of it to solve
# one problem its own header explains: `flutter run` reads keystrokes from a
# TTY, so a backgrounded one takes an stdin EOF and dies at once. Zola, Vite and
# their kin do not have that problem. They read nothing from stdin, speak no
# protocol, and watch their own files for changes, so `nohup <cmd> >log 2>&1 &`
# with a pid file holds them entirely. Routing them through machinery built for
# a problem they do not have would turn half of that file into "only when this
# is a Flutter daemon". Vilya is smaller than Narya, not a copy of it.
#
# The forty-odd lines of lifecycle scaffolding below — state dir, pid file,
# meta, reap — do repeat Narya's shape. That is a judgment taken knowingly in
# docs/plans/vilya-local-server-daemon.md rather than an oversight: the two
# files' spines differ (one holds a protocol, one holds a plain process), and an
# abstraction drawn over a single sibling would be shaped by that sibling alone.
# Revisit at the third holder, or sooner if the repeated part starts drifting.
#
# Usage:
#   vilya.sh start  --name <name> [--project <dir>] [--url <u>] [--label <l>]
#                   [--ready-pattern <regex>] -- <command...>
#   vilya.sh ready  --name <name> [--project <dir>] [--since <bytes>] [--timeout <s>]
#   vilya.sh status --name <name> [--project <dir>]
#   vilya.sh stop   --name <name> [--project <dir>]
#   vilya.sh log    --name <name> [--project <dir>] [-n <lines>]
#
# One server per (project, name) pair. Narya keys on (project, device) because a
# project may hold several simulators; here one project may hold several servers
# at once — a web dev server and an API mock — so the name is the slot. Every
# verb takes an explicit --name: fanning out across a project's unnamed servers
# is deferred until the want proves real.
#
# State lives under $SKADI_VILYA_ROOT (default $HOME/.skadi/vilya)/<slug>/<name>/
# — the pid, the server's log, and a meta file naming the project, name, command
# and start time.
#
# A server whose URL can be learned is registered on the statusline's standing-
# windows row, so it becomes a link a person can click rather than a port they
# must remember. `--url` is authoritative; absent it, the first http(s):// the
# server printed into its own log is taken — zola announces "Web server is
# available at…", Vite prints "Local: …", the same technique Narya uses for the
# DevTools banner. Neither found means no registration, and `start` still
# succeeds: the registry is an ornament on the hold, never a condition of it.
# `--label` names the row; absent it, the server's own name does.
#
# READINESS, AND WHY IT IS NOT A SLEEP
# A caller that edits a file and then screenshots the page must know when the
# rebuild has reached the served bytes. Waiting a fixed few seconds and hoping
# is a race, not an answer: too short and the shot shows the old page as though
# the mend did nothing, too long and every pass pays for the worst case.
# `universal.md` names the cure — where completion is knowable, signal it
# directly. A dev server does announce itself, in its own log, in its own words,
# so `--ready-pattern` at `start` records that phrasing and `ready` waits on it,
# exiting 0 the moment it appears. Owning the process is what makes the log
# reachable, and the log is where the signal lives.
#
# `--since <bytes>` is what makes the answer trustworthy on the SECOND pass. A
# server that announced itself once has that line in its log forever, so a bare
# match would answer "ready" for a rebuild that has not begun. Read the log's
# size before triggering the edit, hand it back as --since, and only an
# announcement made after that moment counts.
#
# The pattern is an extended regular expression, not literal text, so a banner
# pasted whole can defeat itself: "compiled (1234ms)" reads its own parentheses
# as a group and so matches only the text without them. Name a short, stable
# fragment — "compiled", "ready in", "Serving HTTP" — rather than a whole line.
#
# WHAT THIS DOES NOT HOLD
#   - A server that daemonizes itself (double-forks and returns) leaves a pid
#     file naming a process that has already exited. Most dev servers stay in
#     the foreground; a self-daemonizing one is out of scope rather than
#     silently mishandled.
#   - `stop` kills the process it spawned, not that process's children. A server
#     that forks workers of its own (some `npm run dev` shapes) may leave them
#     behind. Named rather than papered over.
#   - `nohup`'s behaviour under MSYS / Git Bash is unproven — Narya's header
#     records that MSYS's `bin/flutter` execs through `cmd.exe`. Vilya needs no
#     fifo at all, so the hazard is smaller, but it has been tested on Linux
#     only. Do not trust it on Windows until someone has watched it there.
#
# Exit codes — a caller's loop branches on these rather than on prose:
#   0 — done
#   1 — the state directory could not be laid down
#   2 — bad arguments
#   4 — no server by that name for this project
#   5 — the server's process is gone: it died as it started, died while `ready`
#       waited on it, or has since exited. `stop` clears the corpse, and
#       `start` raises a new one
#   6 — readiness cannot be known: the server carries no ready pattern. A
#       caller reading this should fall back to whatever it did before Vilya,
#       not treat the server as ready
#   7 — the ready pattern never came within the timeout — treat what the server
#       serves as stale
#
# Runs under macOS bash 3.2 — no declare -A, no mapfile, no ${var,,}.
set -u

ROOT="${SKADI_VILYA_ROOT:-$HOME/.skadi/vilya}"
LOG_LINES_DEFAULT=40
# A spawn that dies in its first breath — a command that is not there, a port
# already taken — must not be reported as a success, and this pause is the whole
# of what stands between such a corpse and a false "started". Say plainly what
# that means: a server whose crash surfaces later than this budget WILL be
# reported started, and only the next `status` will correct the record. That is
# the fixed delay universal.md warns against, carried knowingly for one cut —
# the `ready` verb and its per-server log pattern are what replace it, and until
# they land the failure is at least loud on the next question asked.
SPAWN_SETTLE_SECONDS=0.5
# Half-second ticks to wait for a killed server to go before insisting with -9.
REAP_PATIENCE=10
# How long `ready` waits by default. Matched to Narya's own poke timeout: a cold
# Vite or webpack start is the slow case this must not cut short.
READY_TIMEOUT_DEFAULT=120
# window-register.sh is a sibling in this same hooks/ directory, installed
# alongside this file by the same /install run — so a relative lookup off this
# script's own path holds on every machine, unlike a hardcoded absolute one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# flutter-daemon.sh's next_id() guards its own counter this way; the reason here
# is sharper, since these values reach arithmetic that would otherwise abort the
# script with a code the exit table has already spoken for. `*[!0-9]*` refuses a
# negative too: the minus sign is not a digit.
require_count() { # flag value
  case "$2" in
    ''|*[!0-9]*)
      echo "vilya: $1 wants a whole number, not '$2'" >&2
      usage
      exit 2
      ;;
  esac
}

usage() {
  cat >&2 <<'USAGE'
usage: vilya.sh <verb> --name <name> [flags]
  start  --name <name> [--project <dir>] [--url <u>] [--label <l>]
         [--ready-pattern <regex>] -- <command...>
  ready  --name <name> [--project <dir>] [--since <bytes>] [--timeout <s>]
  status --name <name> [--project <dir>]
  stop   --name <name> [--project <dir>]
  log    --name <name> [--project <dir>] [-n <lines>]

One server per (project, name). Every verb needs its name; the command to run
follows `--` on start. `ready` blocks until the server's own log says it is
serving, so a caller can act on a signal rather than on a guess.
USAGE
}

# The project a verb speaks for: an explicit --project, else the nearest
# ancestor bearing a .git, else $PWD. Narya finds a Flutter project by its
# pubspec.yaml; a protocol-less server has no marker of its own, so the repo
# root is the honest stand-in. `-e` rather than `-d`: a worktree's .git is a
# file, not a directory.
resolve_project() {
  local d
  if [ -n "$project" ]; then
    ( cd "$project" 2>/dev/null && pwd ) && return 0
    echo "vilya: no such directory: $project" >&2
    return 1
  fi
  d="$PWD"
  while [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  echo "$PWD"
}

# The cksum suffix keeps two projects of the same basename apart, which a bare
# basename would collide.
project_dir() { # project
  local sum
  sum="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  echo "$ROOT/$(basename "$1")-$sum"
}

# A bare name turned into a safe directory component; this only guards the rare
# stray character, since a slot name is usually already filesystem-safe.
name_slug() { # name
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# A pure function of its two arguments: it names where a server for that pair
# WOULD live, whether or not one has ever been raised there.
state_dir() { # project name
  printf '%s/%s\n' "$(project_dir "$1")" "$(name_slug "$2")"
}

# A name for the statusline registry, stable and unique enough that two
# projects — or two servers of the same project — never collide: the state dir
# already encodes both (the cksum-suffixed project directory, then the name
# slug), so composing the two carries that apart.
window_name() { # dir
  printf 'vilya-%s-%s\n' "$(basename "$(dirname "$1")")" "$(basename "$1")"
}

# The first address the server announced in its own log. The character class
# stops at whitespace, at control bytes (a colourised dev server wraps its URL
# in ANSI escapes) and at the punctuation that commonly closes one — python's
# own banner reads "(http://127.0.0.1:8000/)", whose bracket is not part of the
# address. A trailing sentence mark is trimmed after the fact for the same
# reason.
first_url_in_log() { # dir
  grep -oE 'https?://[^[:space:][:cntrl:]<>"'"'"')]+' "$1/log" 2>/dev/null \
    | head -n 1 \
    | sed 's/[.,;:]*$//'
}

# Has the ready pattern appeared at or after a byte offset? `tail -c +N` is
# specified by POSIX to count from the beginning, one-based, so an offset of 0 —
# the whole log — is +1. GNU and BSD agree on that reading, but only the GNU one
# has been run here; a macOS check is still owed, the same caveat this file
# already carries for nohup.
pattern_seen() { # dir offset pattern
  tail -c "+$(($2 + 1))" "$1/log" 2>/dev/null | grep -qE "$3"
}

# Narya's await_result in a simpler key: poll in half-second ticks until the
# answer comes or the budget runs out. The liveness check is what keeps a caller
# from waiting the full timeout on a corpse — a server that has died will never
# announce anything. It is asked AFTER the pattern, so a server that announces
# itself and then exits still counts as having answered.
await_ready() { # dir offset pattern timeout
  local waited=0 ticks=$(($4 * 2))
  while :; do
    pattern_seen "$1" "$2" "$3" && return 0
    server_alive "$1" || return 5
    [ "$waited" -ge "$ticks" ] && return 7
    sleep 0.5
    waited=$((waited + 1))
  done
}

# The statusline row is an ornament on the hold, never a condition of it: a
# missing window-register.sh (an older installed root that predates it) or a
# server that never printed an address must not fail `start` itself — this
# always returns success.
#
# It reads this invocation's own --url and --label, and nothing of them is kept
# in meta: a later bare `start` against the same standing server re-derives the
# address from the log and re-labels the row with the plain name. That is the
# ornament's price, and it is cheap — pass the flags again to keep them.
register_window() { # dir name
  local address
  [ -x "$SCRIPT_DIR/window-register.sh" ] || return 0
  address="${url:-$(first_url_in_log "$1")}"
  [ -n "$address" ] || return 0
  "$SCRIPT_DIR/window-register.sh" register "$(window_name "$1")" "$address" \
    "${label:-$2}" >/dev/null 2>&1
  return 0
}

meta_get() { # dir key
  [ -f "$1/meta" ] || return 1
  sed -n "s/^$2=//p" "$1/meta" | head -n 1
}

meta_set() { # dir key value
  local tmp="$1/meta.tmp"
  [ -f "$1/meta" ] && grep -v "^$2=" "$1/meta" > "$tmp" 2>/dev/null
  printf '%s=%s\n' "$2" "$3" >> "$tmp"
  mv "$tmp" "$1/meta"
}

# The log, not the directory, is the proof a server was ever raised here: a
# spawn that fails before it can lay one down leaves the directory behind with
# nothing in it, and `log` would then answer with a filesystem error where a
# plain "no such server" belongs. Every verb asks this one question; what each
# says when the answer is no differs by verb, so only the question is lifted —
# an absence is a plain report for `status` and `stop`, an error for `log`,
# which has nothing left to print.
server_known() { # dir
  [ -f "$1/log" ]
}

require_server() { # dir project name
  server_known "$1" && return 0
  echo "vilya: no server named $3 for $2 — start one first" >&2
  return 4
}

server_alive() { # dir
  [ -f "$1/pid" ] || return 1
  kill -0 "$(cat "$1/pid" 2>/dev/null)" 2>/dev/null
}

spawn_server() { # dir project name
  local pid
  mkdir -p "$1" || return 1
  : > "$1/log" || return 1
  # No pipe apparatus: the server reads nothing, so stdin is closed outright
  # rather than held open by a writer. The `cd` matters — a dev server resolves
  # its config relative to the project root, not to wherever the caller stood —
  # and `exec` keeps the pid the subshell was given, so $! names the server.
  ( cd "$2" && exec nohup "${cmd[@]}" ) > "$1/log" 2>&1 < /dev/null &
  pid=$!
  disown 2>/dev/null || true
  printf '%s\n' "$pid" > "$1/pid"
  : > "$1/meta"
  meta_set "$1" project "$2"
  meta_set "$1" name "$3"
  # Joined for the reader's sake; a command whose arguments bore spaces will not
  # round-trip from here, so nothing reads this back to re-run anything.
  meta_set "$1" command "${cmd[*]}"
  [ -n "$ready_pattern" ] && meta_set "$1" readyPattern "$ready_pattern"
  meta_set "$1" started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

last_words() { # dir what
  echo "vilya: $2 — its last words:" >&2
  tail -n 5 "$1/log" >&2
}

# Tear a server down whole. Both `stop` and a `start` that finds a corpse come
# through here, and the statusline row, if one was ever drawn, is taken down
# here too — the one place every teardown path passes, rather than at each call
# site separately.
reap() { # dir
  local pid waited=0
  [ -x "$SCRIPT_DIR/window-register.sh" ] && \
    "$SCRIPT_DIR/window-register.sh" unregister "$(window_name "$1")" >/dev/null 2>&1
  pid="$(cat "$1/pid" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$REAP_PATIENCE" ]; do
      sleep 0.5
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
  fi
  rm -rf "$1"
}

cmd_start() { # dir project name
  if server_alive "$1"; then
    # A pattern named on a later `start` takes, rather than being silently
    # dropped because the spawn was skipped.
    [ -n "$ready_pattern" ] && meta_set "$1" readyPattern "$ready_pattern"
    register_window "$1" "$3"
    echo "alive $3 · $2 · pid $(cat "$1/pid")"
    return 0
  fi
  [ -d "$1" ] && reap "$1"
  spawn_server "$1" "$2" "$3" || {
    echo "vilya: the state directory could not be laid down under $1" >&2
    return 1
  }
  sleep "$SPAWN_SETTLE_SECONDS"
  # The corpse is left standing rather than reaped, so `log` can still say what
  # went wrong. `stop` clears it when the reader is done with it.
  server_alive "$1" || { last_words "$1" "the server died as it started"; return 5; }
  # A server slower to announce itself than the settle budget prints its address
  # after this reads the log, so nothing is registered on that first `start`. A
  # later `start` finds it alive and registers it then — and the `ready` verb,
  # when it lands, is what will make the first attempt reliable.
  register_window "$1" "$3"
  echo "started $3 · $2 · pid $(cat "$1/pid")"
}

cmd_status() { # dir project name
  server_known "$1" || { echo "none $3 · $2 — no such server"; return 4; }
  server_alive "$1" || { echo "dead $3 · $2 — the process is gone, start it again"; return 5; }
  echo "alive $3 · $2 · pid $(cat "$1/pid") · since $(meta_get "$1" started)"
}

cmd_ready() { # dir project name
  local pattern
  server_known "$1" || { echo "none $3 · $2 — no such server"; return 4; }
  server_alive "$1" || { echo "dead $3 · $2 — the process is gone, start it again"; return 5; }
  pattern="$(meta_get "$1" readyPattern)"
  [ -n "$pattern" ] || {
    echo "vilya: $3 carries no ready pattern — raise it with --ready-pattern to make readiness knowable" >&2
    return 6
  }
  await_ready "$1" "$since" "$pattern" "$timeout"
  case $? in
    0) echo "ready $3 · $2"; return 0 ;;
    5) last_words "$1" "the server died before it was ready"; return 5 ;;
    *)
      echo "vilya: $3 did not announce itself within ${timeout}s — treat what it serves as stale" >&2
      return 7
      ;;
  esac
}

cmd_stop() { # dir project name
  server_known "$1" || { echo "none $3 · $2 — no such server"; return 4; }
  reap "$1"
  echo "stopped $3 · $2"
}

project=""
name=""
url=""
label=""
ready_pattern=""
since=0
timeout="$READY_TIMEOUT_DEFAULT"
lines="$LOG_LINES_DEFAULT"
cmd=()

verb="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; cmd=(${@+"$@"}); break ;;
    --project|--name|--url|--label|--ready-pattern|--since|--timeout|-n)
      [ $# -ge 2 ] || { echo "vilya: $1 needs a value" >&2; usage; exit 2; }
      case "$1" in
        --project) project="$2" ;;
        --name) name="$2" ;;
        --url) url="$2" ;;
        --label) label="$2" ;;
        --ready-pattern) ready_pattern="$2" ;;
        --since) require_count --since "$2"; since="$2" ;;
        --timeout) require_count --timeout "$2"; timeout="$2" ;;
        -n) require_count -n "$2"; lines="$2" ;;
      esac
      shift 2
      ;;
    *) echo "vilya: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$verb" in
  start|ready|status|stop|log) ;;
  *) usage; exit 2 ;;
esac

[ -n "$name" ] || { echo "vilya: every verb needs --name <name>" >&2; usage; exit 2; }

proj="$(resolve_project)" || exit 2
dir="$(state_dir "$proj" "$name")"

case "$verb" in
  start)
    [ "${#cmd[@]}" -gt 0 ] || {
      echo "vilya: start needs a command after --" >&2
      usage
      exit 2
    }
    cmd_start "$dir" "$proj" "$name"
    ;;
  ready)
    cmd_ready "$dir" "$proj" "$name"
    ;;
  status)
    cmd_status "$dir" "$proj" "$name"
    ;;
  stop)
    cmd_stop "$dir" "$proj" "$name"
    ;;
  log)
    require_server "$dir" "$proj" "$name" || exit 4
    tail -n "$lines" "$dir/log"
    ;;
esac
