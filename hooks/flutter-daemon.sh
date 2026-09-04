#!/usr/bin/env bash
# flutter-daemon.sh — a long-lived `flutter run --machine` session that any later
# turn, session, or skill can poke for a hot reload.
#
# WHY A DAEMON AT ALL
# A plain `flutter run` started from a background Bash call dies at once: it reads
# keystrokes from a TTY, and a backgrounded process has no interactive stdin, so it
# hits EOF and exits. Every mend then pays a full rebuild-install-launch cycle, and
# the app comes back at its start screen — the navigation lost with it.
#
# `flutter run --machine` is the daemon protocol IDE plugins drive: newline-delimited
# JSON in, newline-delimited JSON out. Its stdin is the read end of `tail -f` on a
# plain command file: any later process triggers a reload by appending one line,
# and `tail -f` never reaches EOF on its own, so the daemon's stdin never closes
# under it. A named pipe (`mkfifo`) would do the same job on Linux and macOS, but
# a native Windows process cannot read one as stdin — MSYS/Git Bash's `bin/flutter`
# execs `flutter.bat` through `cmd.exe`, and `cmd.exe` handed an MSYS-emulated
# fifo dies at once. The shell's own `|` is a real OS pipe on every platform,
# `cmd.exe` included, so `tail -f cmds | flutter run --machine` is one code path
# that holds everywhere.
#
# WHAT HOT RELOAD CANNOT CARRY
# `reload` covers Dart source only. Changes to main(), top-level or static
# initializers, enum shapes, or native/asset config need `restart`, and a change to
# the native build needs a genuine rebuild. A caller that assumes `reload` always
# suffices will compare against a stale binary — a worse failure than a slow one.
#
# Usage:
#   flutter-daemon.sh start [--project <dir>] [-d <device>] [--flavor <f>]
#                           [-t <entry>] [--timeout <s>] [-- <extra flutter args>]
#   flutter-daemon.sh reload  [--project <dir>] [-d <device>] [--timeout <s>]   # hot reload
#   flutter-daemon.sh restart [--project <dir>] [-d <device>] [--timeout <s>]   # hot restart
#   flutter-daemon.sh status  [--project <dir>] [-d <device>]
#   flutter-daemon.sh stop    [--project <dir>] [-d <device>]
#   flutter-daemon.sh log     [--project <dir>] [-d <device>] [-n <lines>]
#
# One daemon per (project, device) pair. With no --project the project is the
# nearest ancestor of $PWD bearing a pubspec.yaml. `start -d <device>` names
# which slot to raise or resume; an unqualified `start` resumes the project's
# one standing daemon exactly as before, and — only when none stands yet —
# raises the project's own default slot. Naming a device `start` has never
# raised yet always adds a sibling alongside the others, so one project can
# hold several simulators at once. Once two or more already stand, an
# unqualified `start` refuses rather than guess which to resume or add a third
# unlabeled one — name one with -d.
#
# Every other verb, given an explicit -d, speaks to that one slot only. Left
# unqualified: with a single slot standing it behaves exactly as a one-device
# project always has; with two or more, `reload`/`restart`/`status`/`stop` act
# on every one of them, one line per device (prefixed "[<device>] "), and `log`
# refuses rather than interleave several transcripts — name one with -d.
#
# State lives under $SKADI_FLUTTER_ROOT (default $HOME/.skadi/flutter)/
# <slug>/<device-slug>/ — the command file, the daemon's log, the two pids, and
# a meta file naming the project, device, flavor, entry and appId.
#
# Device id, flavor and entry point are arguments, never baked in: this hook must
# read true in any Flutter project on any machine.
#
# Exit codes — a caller's loop branches on these rather than on prose:
#   0 — done
#   1 — the state directory or its pipe could not be laid down
#   2 — bad arguments
#   3 — flutter not found (neither `flutter` nor `fvm flutter`)
#   4 — no daemon for this project/device (or, for start, no pubspec.yaml there)
#   5 — the daemon cannot be reached: either the process is gone, or it lives and
#       nothing reads its pipe. `stop` clears both, and `start` raises a new one —
#       `start` alone would find the wedged one alive and do nothing
#   6 — the daemon lives, but the app has not reached app.started yet
#   7 — the reload/restart failed, or went unanswered — the app is stale either way
#
# A fanned-out reload/restart/status/stop (no -d, more than one device standing)
# returns 0 only if every targeted device reported 0; otherwise the worst code
# seen, with 7 taking priority — that is the one a caller must never read past.
#
# Runs under macOS bash 3.2 — no declare -A, no mapfile, no ${var,,}.
set -u

ROOT="${SKADI_FLUTTER_ROOT:-$HOME/.skadi/flutter}"
START_TIMEOUT_DEFAULT=300
POKE_TIMEOUT_DEFAULT=120
LOG_LINES_DEFAULT=40

usage() {
  cat >&2 <<'USAGE'
usage: flutter-daemon.sh <verb> [flags]
  start   [--project <dir>] [-d <device>] [--flavor <f>] [-t <entry>] [--timeout <s>] [-- <flutter args>]
  reload  [--project <dir>] [-d <device>] [--timeout <s>]
  restart [--project <dir>] [-d <device>] [--timeout <s>]
  status  [--project <dir>] [-d <device>]
  stop    [--project <dir>] [-d <device>]
  log     [--project <dir>] [-d <device>] [-n <lines>]

A second 'start' with a different -d raises a sibling daemon for the same
project. Every other verb, left unqualified, acts on all of them once more
than one stands (log requires -d then, to avoid interleaving transcripts).
USAGE
}

find_flutter() {
  if command -v flutter >/dev/null 2>&1; then echo "flutter"; return 0; fi
  if command -v fvm >/dev/null 2>&1; then echo "fvm flutter"; return 0; fi
  return 1
}

# The project a bare verb speaks for: an explicit --project, else the nearest
# ancestor bearing a pubspec.yaml, else $PWD.
resolve_project() {
  local d
  if [ -n "$project" ]; then
    ( cd "$project" 2>/dev/null && pwd ) && return 0
    echo "flutter-daemon: no such directory: $project" >&2
    return 1
  fi
  d="$PWD"
  while [ "$d" != "/" ]; do
    if [ -f "$d/pubspec.yaml" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  echo "$PWD"
}

project_dir() { # project
  local sum
  sum="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  echo "$ROOT/$(basename "$1")-$sum"
}

# A bare device string turned into a safe directory component. Flutter device
# ids (emulator-5554, an iOS simulator UUID, macos, chrome) are already mostly
# filesystem-safe; this only guards the rare stray character. Unset or empty
# names the project's own default slot — the one a single-device project has
# always used.
device_slug() { # device (possibly empty)
  printf '%s' "${1:-default}" | tr -c 'A-Za-z0-9._-' '_'
}

# One daemon lives at project_dir/device_slug — a project's default slot when
# device is empty, a sibling slot per additional device otherwise. This is a
# pure function of its two arguments: it names where a daemon for that pair
# WOULD live, whether or not one has ever been raised there.
state_dir() { # project device
  printf '%s/%s\n' "$(project_dir "$1")" "$(device_slug "$2")"
}

# Every device slot for a project that has ever seen `start` succeed — a log
# file is the same proof require_daemon leans on below: a spawn that never got
# that far leaves a directory with nothing worth polling. Prints one slug per
# line; silent (not an error) when the project has never been started at all.
list_device_dirs() { # proj_dir
  local d
  [ -d "$1" ] || return 0
  for d in "$1"/*/; do
    [ -f "${d}log" ] || continue
    basename "$d"
  done
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

# The daemon protocol reader. Each protocol line is a JSON list of one message;
# flutter also prints plain prose before the protocol starts, which is skipped.
#   dproto appid  <log>                 -> appId once app.started has been seen
#   dproto result <log> <offset> <id>   -> "<code>\t<message>" for that request
dproto() {
  python3 - "$@" <<'PY'
import json, sys

mode, path = sys.argv[1], sys.argv[2]


def messages(fp):
    for raw in fp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("["):
            continue
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        for message in parsed:
            if isinstance(message, dict):
                yield message


if mode == "appid":
    started, app = False, None
    with open(path, "rb") as fp:
        for m in messages(fp):
            event = m.get("event")
            if event in ("app.start", "app.started"):
                app = (m.get("params") or {}).get("appId") or app
            if event == "app.started":
                started = True
    if started and app:
        print(app)
        sys.exit(0)
    sys.exit(1)

if mode == "result":
    offset, want = int(sys.argv[3]), int(sys.argv[4])
    with open(path, "rb") as fp:
        fp.seek(offset)
        for m in messages(fp):
            if m.get("id") != want:
                continue
            if "error" in m:
                print("1\t%s" % m["error"])
                sys.exit(0)
            result = m.get("result") or {}
            print("%s\t%s" % (result.get("code", 0), result.get("message", "")))
            sys.exit(0)
    sys.exit(1)

sys.exit(2)
PY
}

# The log, not the directory, is the proof a daemon was ever raised here: a spawn
# that fails to lay down its command file leaves the directory behind with nothing
# in it, and every verb below reads the log — `tail` on a file that is not there
# would answer with a filesystem error where a plain "no daemon" belongs.
require_daemon() { # dir project
  [ -f "$1/log" ] && return 0
  echo "flutter-daemon: no daemon for $2 — start one first" >&2
  return 4
}

daemon_alive() { # dir
  [ -f "$1/daemon.pid" ] || return 1
  kill -0 "$(cat "$1/daemon.pid" 2>/dev/null)" 2>/dev/null
}

# The appId is learned from the log, not assumed: a slow first build means `start`
# may return before app.started arrives, and a later verb picks it up instead.
resolve_appid() { # dir
  local app
  app="$(meta_get "$1" appId)"
  if [ -n "$app" ]; then echo "$app"; return 0; fi
  app="$(dproto appid "$1/log" 2>/dev/null)" || return 1
  meta_set "$1" appId "$app"
  echo "$app"
}

# Appending to the command file never blocks — unlike the fifo write it replaces,
# a plain file has no reader to wait for. A daemon that has stopped consuming
# commands is instead caught downstream, by await_result's own timeout.
send_command() { # dir line
  printf '%s\n' "$2" >> "$1/cmds"
}

next_id() { # dir
  local n
  n="$(cat "$1/req" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$1/req"
  echo "$n"
}

spawn_daemon() { # dir project
  local daemon
  mkdir -p "$1" || return 1
  : > "$1/cmds" || return 1
  : > "$1/log"
  rm -f "$1/holder.pid"
  # shellcheck disable=SC2086
  # `flutter run` must be spoken from the project root, not from wherever the
  # caller stood; `exec` keeps the pid the subshell was given, so $! still names
  # the daemon itself. $fl splits "fvm flutter" into command + subcommand.
  #
  # The left stage writes its own pid to holder.pid before exec'ing into
  # `tail -f` — `$!` after a backgrounded pipeline names only its last stage,
  # and a freshly invoked `sh -c` computes its own $$ correctly, where a bash
  # `()` subshell would report the caller's pid instead. Its stderr is sent
  # to /dev/null, not left inherited: `tail -f` never exits, so a caller that
  # captures this script's own output via `$(...)` would wait forever for an
  # EOF that an inherited fd on a process this long-lived would never send.
  sh -c 'echo $$ > "$1"; exec tail -f "$2"' _ "$1/holder.pid" "$1/cmds" 2>/dev/null \
    | ( cd "$2" && exec nohup $fl run --machine \
      ${device:+-d "$device"} ${flavor:+--flavor "$flavor"} ${entry:+-t "$entry"} \
      ${extra[@]+"${extra[@]}"} ) > "$1/log" 2>&1 &
  daemon=$!
  disown 2>/dev/null || true
  printf '%s\n' "$daemon" > "$1/daemon.pid"
  : > "$1/meta"
  meta_set "$1" project "$2"
  meta_set "$1" device "${device:-default}"
  meta_set "$1" flavor "${flavor:-none}"
  meta_set "$1" entry "${entry:-default}"
  meta_set "$1" started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Tear a daemon down whole. The pipe holder (`tail -f`) goes first — closing it
# closes the pipe's only write end, the very EOF the daemon exits on, the death
# that made a backgrounded `flutter run` useless, put to work as the shutdown.
# Both `stop` and a `start`
# that finds a corpse come through here: a holder outliving its state directory
# would sit on a pipe that no longer has a name, and one more would be stranded
# on every restart-after-death.
reap() { # dir
  local pid waited=0
  [ -f "$1/holder.pid" ] && kill "$(cat "$1/holder.pid")" 2>/dev/null
  pid="$(cat "$1/daemon.pid" 2>/dev/null)"
  while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -rf "$1"
}

last_words() { # dir what
  echo "flutter-daemon: $2 — its last words:" >&2
  tail -n 5 "$1/log" >&2
}

await_started() { # dir timeout
  local waited=0 app
  while [ "$waited" -lt "$2" ]; do
    if app="$(resolve_appid "$1")"; then echo "$app"; return 0; fi
    daemon_alive "$1" || return 2
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

await_result() { # dir offset id timeout label
  local waited=0 out code msg
  while [ "$waited" -lt $(($4 * 2)) ]; do
    if out="$(dproto result "$1/log" "$2" "$3")"; then
      code="$(printf '%s' "$out" | cut -f1)"
      msg="$(printf '%s' "$out" | cut -f2-)"
      if [ "$code" = "0" ]; then
        echo "$5ed $(meta_get "$1" appId)${msg:+ · $msg}"
        return 0
      fi
      echo "flutter-daemon: $5 failed — ${msg:-code $code}" >&2
      return 7
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  echo "flutter-daemon: no answer to the $5 within $4s — treat the running app as stale" >&2
  return 7
}

poke() { # dir reload|restart
  local app id offset full=false
  [ "$2" = "restart" ] && full=true
  daemon_alive "$1" || {
    echo "flutter-daemon: the daemon for $(meta_get "$1" project) is gone — stop it, then start it again" >&2
    return 5
  }
  app="$(resolve_appid "$1")" || {
    echo "flutter-daemon: the app has not started yet — check 'log' for the build" >&2
    return 6
  }
  id="$(next_id "$1")"
  offset="$(wc -c < "$1/log" | tr -d ' ')"
  # A write failure wears the same exit code as a corpse because the cure is the
  # same: `start` alone would find this daemon alive and do nothing for it.
  send_command "$1" "[{\"id\":$id,\"method\":\"app.restart\",\"params\":{\"appId\":\"$app\",\"fullRestart\":$full,\"pause\":false,\"reason\":\"manual\"}}]" || {
    echo "flutter-daemon: the command file could not be written — stop it, then start it again" >&2
    return 5
  }
  await_result "$1" "$offset" "$id" "$timeout" "$2"
}

cmd_start() { # dir project
  local app
  if daemon_alive "$1"; then
    if app="$(resolve_appid "$1")"; then
      echo "alive $app · $2 · device $(meta_get "$1" device)"
      return 0
    fi
  else
    [ -d "$1" ] && reap "$1"
    spawn_daemon "$1" "$2" || { echo "flutter-daemon: the pipe could not be laid down under $1" >&2; return 1; }
  fi
  # app.started in the log proves the app once ran, not that it still does — a
  # daemon that died in that same breath must not be reported as a success.
  if app="$(await_started "$1" "$timeout")"; then
    daemon_alive "$1" || { last_words "$1" "the app started, then the daemon died"; return 5; }
    echo "started $app · $2 · device $(meta_get "$1" device)"
    return 0
  fi
  daemon_alive "$1" || { last_words "$1" "the daemon died before the app started"; return 5; }
  echo "flutter-daemon: still building after ${timeout}s — run 'status' to pick it up" >&2
  return 6
}

cmd_status() { # dir project
  local app
  [ -d "$1" ] || { echo "none $2 — no daemon"; return 4; }
  daemon_alive "$1" || { echo "dead $2 — the daemon is gone, start it again"; return 5; }
  if app="$(resolve_appid "$1")"; then
    echo "alive $app · $2 · device $(meta_get "$1" device) · pid $(cat "$1/daemon.pid")"
    return 0
  fi
  echo "starting $2 · pid $(cat "$1/daemon.pid") — no app.started yet"
  return 6
}

cmd_stop() { # dir project
  local app
  [ -d "$1" ] || { echo "none $2 — no daemon"; return 4; }
  app="$(resolve_appid "$1")" && \
    send_command "$1" "[{\"id\":$(next_id "$1"),\"method\":\"app.stop\",\"params\":{\"appId\":\"$app\"}}]"
  reap "$1"
  echo "stopped $2"
}

# Fan-out across every live device slot for a project, for the verbs a bare
# (no -d) call reaches once more than one stands. Each targets its own slot
# through the same single-device path (poke/cmd_status/cmd_stop) — a dead or
# not-yet-started sibling reports its own code without blocking the rest.

# Folds one more device's exit code into a running worst-so-far: unchanged
# once nonzero, except a 7 (stale) always wins — the one code a caller must
# never miss. Shared by every fanout_* below, so the "0 only if every device
# succeeded, else the worst" contract is honored identically by all of them.
worse_of() { # worst-so-far new-code
  if [ "$2" = "0" ]; then echo "$1"; return; fi
  if [ "$2" = "7" ] || [ "$1" = "0" ]; then echo "$2"; else echo "$1"; fi
}

fanout_poke() { # proj_dir slugs verb
  local slug d label out code worst=0
  for slug in $2; do
    d="$1/$slug"
    label="$(meta_get "$d" device)"
    out="$(poke "$d" "$3" 2>&1)"; code=$?
    printf '%s\n' "$out" | sed "s/^/[$label] /"
    worst="$(worse_of "$worst" "$code")"
  done
  return "$worst"
}

fanout_status() { # proj_dir slugs project
  local slug worst=0
  for slug in $2; do
    cmd_status "$1/$slug" "$3"
    worst="$(worse_of "$worst" "$?")"
  done
  return "$worst"
}

fanout_stop() { # proj_dir slugs project
  local slug worst=0
  for slug in $2; do
    cmd_stop "$1/$slug" "$3"
    worst="$(worse_of "$worst" "$?")"
  done
  return "$worst"
}

project=""
device=""
device_given=0
flavor=""
entry=""
timeout=""
lines="$LOG_LINES_DEFAULT"
extra=()

verb="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; extra=(${@+"$@"}); break ;;
    --project|-d|--device|--flavor|-t|--target|--timeout|-n)
      [ $# -ge 2 ] || { echo "flutter-daemon: $1 needs a value" >&2; usage; exit 2; }
      case "$1" in
        --project) project="$2" ;;
        -d|--device) device="$2"; device_given=1 ;;
        --flavor) flavor="$2" ;;
        -t|--target) entry="$2" ;;
        --timeout) timeout="$2" ;;
        -n) lines="$2" ;;
      esac
      shift 2
      ;;
    *) echo "flutter-daemon: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$verb" in
  start|reload|restart|status|stop|log) ;;
  *) usage; exit 2 ;;
esac

proj="$(resolve_project)" || exit 2
proj_dir="$(project_dir "$proj")"

# Every verb, given an explicit -d, targets that one slot — for `start`, the
# device to raise or resume; for the rest, the device to speak to. Left
# unqualified: a single live slot is targeted exactly as a one-device project
# always has ($slugs left empty signals "no fan-out"/"no ambiguity" below);
# two or more leaves $slugs holding every slug — the case block below fans
# reload/restart/status/stop across all of them, and refuses an unqualified
# `start` or `log` outright, since neither can address "all of them" at once.
slugs=""
if [ "$device_given" = "1" ]; then
  dir="$(state_dir "$proj" "$device")"
else
  slugs="$(list_device_dirs "$proj_dir")"
  count="$(printf '%s\n' "$slugs" | grep -c '^.')"
  if [ "$count" -le 1 ]; then
    dir="$proj_dir/${slugs:-$(device_slug "")}"
    slugs=""
  fi
fi

case "$verb" in
  start)
    [ -f "$proj/pubspec.yaml" ] || {
      echo "flutter-daemon: no pubspec.yaml in $proj — name the project with --project <dir>" >&2
      exit 4
    }
    fl="$(find_flutter)" || {
      echo "flutter-daemon: flutter not found — install Flutter or fvm" >&2
      exit 3
    }
    if [ -n "$slugs" ]; then
      echo "flutter-daemon: several devices already run for $proj — name one with -d <device> to resume it, or a new one to add another:" >&2
      for slug in $slugs; do
        echo "  $(meta_get "$proj_dir/$slug" device)" >&2
      done
      exit 2
    fi
    : "${timeout:=$START_TIMEOUT_DEFAULT}"
    cmd_start "$dir" "$proj"
    ;;
  reload|restart)
    : "${timeout:=$POKE_TIMEOUT_DEFAULT}"
    if [ -n "$slugs" ]; then
      fanout_poke "$proj_dir" "$slugs" "$verb"
      exit $?
    fi
    require_daemon "$dir" "$proj" || exit 4
    poke "$dir" "$verb"
    ;;
  status)
    if [ -n "$slugs" ]; then
      fanout_status "$proj_dir" "$slugs" "$proj"
      exit $?
    fi
    cmd_status "$dir" "$proj"
    ;;
  stop)
    if [ -n "$slugs" ]; then
      fanout_stop "$proj_dir" "$slugs" "$proj"
      exit $?
    fi
    cmd_stop "$dir" "$proj"
    ;;
  log)
    if [ -n "$slugs" ]; then
      echo "flutter-daemon: multiple devices running for $proj — name one with -d <device>:" >&2
      for slug in $slugs; do
        echo "  $(meta_get "$proj_dir/$slug" device)" >&2
      done
      exit 2
    fi
    require_daemon "$dir" "$proj" || exit 4
    tail -n "$lines" "$dir/log"
    ;;
esac
