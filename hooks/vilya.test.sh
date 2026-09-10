#!/bin/bash
# Offline tests for the standing holder of protocol-less local servers. Raises a
# real `python3 -m http.server` on a free port, so the assertions weigh a live
# process and a live socket rather than a mock. Run from anywhere:
# bash vilya.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/vilya.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
export SKADI_VILYA_ROOT="$WORK/state"
export SKADI_WINDOWS_DIR="$WORK/windows"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"

# A test that leaves a server running would poison the next run and the machine
# with it, so the trap tears down whatever still stands, however the run ended.
cleanup() {
  "$HOOK" stop --name web --project "$PROJECT" >/dev/null 2>&1
  "$HOOK" stop --name doomed --project "$PROJECT" >/dev/null 2>&1
  "$HOOK" stop --name mute --project "$PROJECT" >/dev/null 2>&1
  "$HOOK" stop --name named --project "$PROJECT" >/dev/null 2>&1
  "$HOOK" stop --name lone --project "$PROJECT" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

port_answers() { # port -> yes|no
  if python3 - "$1" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(1)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
  then echo yes; else echo no; fi
}

# Python's own startup is not instant, and it is not the hook's job to wait for
# it — this patience belongs to the test, not to `start`.
await_port() { # port state(yes|no)
  local waited=0
  while [ "$waited" -lt 100 ]; do
    [ "$(port_answers "$1")" = "$2" ] && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# `kill -0` succeeds on a zombie — a process that has exited but whose parent
# has not yet reaped it — so an immediate read after `stop` can call a dead
# server living. This patience closes that window and nothing wider: it is far
# shorter than the hook's own reap, so a `stop` that genuinely fails to signal
# is still caught rather than waited out.
await_departure() { # pid
  local waited=0
  while [ "$waited" -lt 20 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

PORT="$(free_port)"

# ── start holds a real process, and the port it opened answers ──
"$HOOK" start --name web --project "$PROJECT" \
  -- python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1
start_status=$?
expected_status=0
check "start exits 0" "$expected_status" "$start_status"

project_slug="$(basename "$PROJECT")-$(printf '%s' "$PROJECT" | cksum | awk '{print $1}')"
pid_file="$SKADI_VILYA_ROOT/$project_slug/web/pid"
window_file="$SKADI_WINDOWS_DIR/vilya-$project_slug-web"
expected_pid_file=yes
check "start writes a pid file" "$expected_pid_file" "$([ -f "$pid_file" ] && echo yes || echo no)"

served_pid="$(cat "$pid_file" 2>/dev/null)"
expected_alive=yes
check "the pid names a living process" "$expected_alive" "$(kill -0 "$served_pid" 2>/dev/null && echo yes || echo no)"

await_port "$PORT" yes
expected_answers=yes
check "the port the server opened answers" "$expected_answers" "$(port_answers "$PORT")"

# ── the address the server printed becomes a clickable statusline row ──
expected_registered=yes
check "start registers a standing window" "$expected_registered" \
  "$([ -f "$window_file" ] && echo yes || echo no)"

# python's banner reads "(http://127.0.0.1:PORT/)" — the bracket must not be
# taken for part of the address.
expected_url="http://127.0.0.1:$PORT/"
check "the registered url is the one the server announced" "$expected_url" \
  "$(sed -n '1p' "$window_file" 2>/dev/null)"

expected_label=web
check "the label falls back to the server's name" "$expected_label" \
  "$(sed -n '2p' "$window_file" 2>/dev/null)"

# ── status and log read the standing server ──
status_out="$("$HOOK" status --name web --project "$PROJECT" 2>&1)"
status_code=$?
check "status exits 0 while it stands" "$expected_status" "$status_code"

expected_verdict=alive
check "status reports it alive" "$expected_verdict" "$(printf '%s' "$status_out" | awk '{print $1}')"

# http.server announces itself on stderr, which the hook folds into the log.
log_out="$("$HOOK" log --name web --project "$PROJECT" 2>&1)"
expected_logged=yes
check "log carries the server's own output" "$expected_logged" \
  "$(printf '%s' "$log_out" | grep -q 'Serving HTTP' && echo yes || echo no)"

# ── a second start finds the standing server rather than raising a rival ──
second_out="$("$HOOK" start --name web --project "$PROJECT" \
  -- python3 -m http.server "$PORT" --bind 127.0.0.1 2>&1)"
second_code=$?
check "a second start exits 0" "$expected_status" "$second_code"
check "a second start reports it alive" "$expected_verdict" "$(printf '%s' "$second_out" | awk '{print $1}')"
expected_same_pid="$served_pid"
check "a second start raises no rival" "$expected_same_pid" "$(cat "$pid_file" 2>/dev/null)"

# ── stop takes the process, the state, and the socket with it ──
"$HOOK" stop --name web --project "$PROJECT" >/dev/null 2>&1
stop_code=$?
check "stop exits 0" "$expected_status" "$stop_code"

expected_gone=no
await_departure "$served_pid"
check "the process is gone" "$expected_gone" "$(kill -0 "$served_pid" 2>/dev/null && echo yes || echo no)"
check "the state directory is gone" "$expected_gone" "$([ -d "$(dirname "$pid_file")" ] && echo yes || echo no)"

await_port "$PORT" no
check "the port no longer answers" "$expected_gone" "$(port_answers "$PORT")"
check "stop clears the standing window" "$expected_gone" \
  "$([ -f "$window_file" ] && echo yes || echo no)"

# ── an explicit --url and --label outrank whatever the log says ──
NAMED_PORT="$(free_port)"
"$HOOK" start --name named --project "$PROJECT" \
  --url "http://example.test/named" --label "The Named One" \
  -- python3 -m http.server "$NAMED_PORT" --bind 127.0.0.1 >/dev/null 2>&1
named_window="$SKADI_WINDOWS_DIR/vilya-$project_slug-named"
expected_named_url="http://example.test/named"
check "an explicit --url outranks the log" "$expected_named_url" \
  "$(sed -n '1p' "$named_window" 2>/dev/null)"
expected_named_label="The Named One"
check "an explicit --label names the row" "$expected_named_label" \
  "$(sed -n '2p' "$named_window" 2>/dev/null)"
"$HOOK" stop --name named --project "$PROJECT" >/dev/null 2>&1

# ── a server that announces no address still starts; it simply draws no row ──
"$HOOK" start --name mute --project "$PROJECT" \
  -- sh -c 'echo listening, but I name no address; sleep 30' >/dev/null 2>&1
mute_code=$?
check "a server with no address still starts" "$expected_status" "$mute_code"
check "a server with no address registers nothing" "$expected_gone" \
  "$([ -f "$SKADI_WINDOWS_DIR/vilya-$project_slug-mute" ] && echo yes || echo no)"
"$HOOK" stop --name mute --project "$PROJECT" >/dev/null 2>&1

# ── an installed root with no window-register.sh still holds its server ──
LONE_DIR="$WORK/lone-root"
mkdir -p "$LONE_DIR"
cp "$HOOK" "$LONE_DIR/vilya.sh"
chmod +x "$LONE_DIR/vilya.sh"
LONE_PORT="$(free_port)"
"$LONE_DIR/vilya.sh" start --name lone --project "$PROJECT" \
  -- python3 -m http.server "$LONE_PORT" --bind 127.0.0.1 >/dev/null 2>&1
lone_code=$?
check "a root without window-register.sh still starts a server" "$expected_status" "$lone_code"
check "a root without window-register.sh draws no row" "$expected_gone" \
  "$([ -f "$SKADI_WINDOWS_DIR/vilya-$project_slug-lone" ] && echo yes || echo no)"
"$LONE_DIR/vilya.sh" stop --name lone --project "$PROJECT" >/dev/null 2>&1

# ── a server that dies as it starts is never reported as started ──
"$HOOK" start --name doomed --project "$PROJECT" \
  -- sh -c 'echo the port was taken >&2; exit 1' >/dev/null 2>&1
doomed_code=$?
expected_dead_status=5
check "a stillborn server exits 5" "$expected_dead_status" "$doomed_code"

# Its corpse is left standing on purpose, so the log can still be read for why.
doomed_log="$("$HOOK" log --name doomed --project "$PROJECT" 2>&1)"
expected_reason=yes
check "the stillborn server's log survives for reading" "$expected_reason" \
  "$(printf '%s' "$doomed_log" | grep -q 'the port was taken' && echo yes || echo no)"

"$HOOK" status --name doomed --project "$PROJECT" >/dev/null 2>&1
check "status over a corpse exits 5" "$expected_dead_status" "$?"

"$HOOK" stop --name doomed --project "$PROJECT" >/dev/null 2>&1
check "stop clears the corpse" "$expected_status" "$?"

# ── a name that was never raised is a plain absence, not an error in the tree ──
expected_absent=4
"$HOOK" status --name never-raised --project "$PROJECT" >/dev/null 2>&1
check "status on an unknown name exits 4" "$expected_absent" "$?"
"$HOOK" stop --name never-raised --project "$PROJECT" >/dev/null 2>&1
check "stop on an unknown name exits 4" "$expected_absent" "$?"
"$HOOK" log --name never-raised --project "$PROJECT" >/dev/null 2>&1
check "log on an unknown name exits 4" "$expected_absent" "$?"

# ── malformed invocations refuse rather than guess ──
expected_refused=2
"$HOOK" >/dev/null 2>&1
check "no verb at all exits 2" "$expected_refused" "$?"
"$HOOK" dance --name web >/dev/null 2>&1
check "an unknown verb exits 2" "$expected_refused" "$?"
"$HOOK" status --project "$PROJECT" >/dev/null 2>&1
check "a verb with no --name exits 2" "$expected_refused" "$?"
"$HOOK" start --name web --project "$PROJECT" >/dev/null 2>&1
check "start with no command exits 2" "$expected_refused" "$?"
"$HOOK" start --project "$PROJECT" -- true >/dev/null 2>&1
check "start with no --name exits 2" "$expected_refused" "$?"
"$HOOK" start --name >/dev/null 2>&1
check "a flag with no value exits 2" "$expected_refused" "$?"
"$HOOK" status --name web --heave-ho >/dev/null 2>&1
check "an unknown flag exits 2" "$expected_refused" "$?"
"$HOOK" status --name web --project "$WORK/no-such-place" >/dev/null 2>&1
check "a project directory that is not there exits 2" "$expected_refused" "$?"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
