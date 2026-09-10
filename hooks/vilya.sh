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
#                   -- <command...>
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
#   5 — the server's process is gone: it died as it started, or it has since
#       exited. `stop` clears the corpse, and `start` raises a new one
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
# window-register.sh is a sibling in this same hooks/ directory, installed
# alongside this file by the same /install run — so a relative lookup off this
# script's own path holds on every machine, unlike a hardcoded absolute one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
usage: vilya.sh <verb> --name <name> [flags]
  start  --name <name> [--project <dir>] [--url <u>] [--label <l>] -- <command...>
  status --name <name> [--project <dir>]
  stop   --name <name> [--project <dir>]
  log    --name <name> [--project <dir>] [-n <lines>]

One server per (project, name). Every verb needs its name; the command to run
follows `--` on start.
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

cmd_stop() { # dir project name
  server_known "$1" || { echo "none $3 · $2 — no such server"; return 4; }
  reap "$1"
  echo "stopped $3 · $2"
}

project=""
name=""
url=""
label=""
lines="$LOG_LINES_DEFAULT"
cmd=()

verb="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; cmd=(${@+"$@"}); break ;;
    --project|--name|--url|--label|-n)
      [ $# -ge 2 ] || { echo "vilya: $1 needs a value" >&2; usage; exit 2; }
      case "$1" in
        --project) project="$2" ;;
        --name) name="$2" ;;
        --url) url="$2" ;;
        --label) label="$2" ;;
        -n) lines="$2" ;;
      esac
      shift 2
      ;;
    *) echo "vilya: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$verb" in
  start|status|stop|log) ;;
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
