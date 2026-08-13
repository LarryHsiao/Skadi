#!/bin/bash
# Offline tests for board-server.py's stability routes. Boots the real server
# against a temp board dir with BOARD_STABILITY_BIN pointed at a stub script,
# so the HTTP routing is exercised without touching BigQuery.
# Run: bash board-server.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/board-server.py"
pass=0
fail=0

ROOT="$(mktemp -d)"
STUB="$ROOT/stub-stability.py"
PORT="$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")"

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  # Section 9 boots its server through board.sh, which nohups and disowns it —
  # there is no PID to hold, so it is felled by the port it was given.
  [[ -n "${PORT2:-}" ]] && pkill -f "board-server.py $PORT2" 2>/dev/null
  [[ -n "${PORT3:-}" ]] && pkill -f "board-server.py $PORT3" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

cat >"$STUB" <<'PY'
#!/usr/bin/env python3
import json, sys
cmd = sys.argv[1]
if cmd == "list-apps":
    print(json.dumps([{"label": "stub-app · na · ANDROID"}]))
    sys.exit(0)
if cmd == "fetch":
    label = sys.argv[2]
    if label == "stub-app · na · ANDROID":
        print(json.dumps({"label": label, "crash_free_pct": 99.2}))
        sys.exit(0)
    sys.stderr.write("board-stability: no app bound with label %r\n" % label)
    sys.exit(1)
sys.exit("unknown cmd")
PY

BOARD_STABILITY_BIN="$STUB" python3 "$SERVER" "$PORT" "$ROOT" &
SERVER_PID=$!

# Wait for the server to answer rather than a fixed sleep.
up=""
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/stability/apps"; then
    up=1
    break
  fi
  sleep 0.1
done
if [[ -z "$up" ]]; then
  echo "FAIL · server never came up on port $PORT"
  exit 1
fi

# ── 1 · GET /stability/apps lists the stub roster ──
expected_label="stub-app · na · ANDROID"
actual_label="$(curl -s "http://127.0.0.1:$PORT/stability/apps" | jq -r '.[0].label')"
check "apps route returns the stub roster" "$expected_label" "$actual_label"

# ── 2 · GET /stability/fetch?label=<known> returns its number ──
expected_pct="99.2"
actual_pct="$(curl -s -G --data-urlencode "label=stub-app · na · ANDROID" \
  "http://127.0.0.1:$PORT/stability/fetch" | jq -r '.crash_free_pct')"
check "fetch route returns the stub's crash-free pct" "$expected_pct" "$actual_pct"

# ── 3 · GET /stability/fetch with an unknown label surfaces the error, not a 500 ──
expected_status="400"
actual_status="$(curl -s -o /dev/null -w '%{http_code}' \
  --data-urlencode "label=nope" -G "http://127.0.0.1:$PORT/stability/fetch")"
check "an unknown label responds 400, not a crash" "$expected_status" "$actual_status"

# ── 4 · GET /stability/fetch with no label is a 400, never reaches the stub ──
expected_missing="400"
actual_missing="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/stability/fetch")"
check "a missing label responds 400" "$expected_missing" "$actual_missing"

# ── 5 · a static file in the board dir still serves — the routing add-on left the base server alone ──
echo '{"ping":"pong"}' >"$ROOT/probe.json"
expected_static='{"ping":"pong"}'
actual_static="$(curl -s "http://127.0.0.1:$PORT/probe.json")"
check "static files still serve alongside the new routes" "$expected_static" "$actual_static"

# ── 6 · GET /handbook/ resolves against the skadi repo, not the (unrelated) board dir ──
expected_handbook_title="<title>Skadi Handbook</title>"
actual_handbook_title="$(curl -s "http://127.0.0.1:$PORT/handbook/" | grep -o '<title>Skadi Handbook</title>')"
check "handbook route serves the repo's handbook cover page" "$expected_handbook_title" "$actual_handbook_title"

# ── 7 · the handbook's relative ../previews/... link resolves through the same route ──
expected_theme_status="200"
actual_theme_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/previews/henneth/skadi-theme.css")"
check "the handbook's theme link resolves under /previews/" "$expected_theme_status" "$actual_theme_status"

# ── 8 · a /previews/../ escape can't reach files outside previews/ ──
# --path-as-is stops curl from collapsing ".." itself, so this exercises what
# the server actually does with the literal bytes a raw client can send.
# CLAUDE.md sits at the skadi repo root, outside previews/ — a server that
# (mis)scoped the whole repo root to this route would happily 200 it.
expected_traversal_status="404"
actual_traversal_status="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$PORT/previews/../CLAUDE.md")"
check "a /previews/../ escape 404s instead of reaching the repo root" "$expected_traversal_status" "$actual_traversal_status"

# ── 9 · the installed copy — hooks whose parent is a config root, not the repo ──
# Every check above runs the repo's own copy, where the hooks folder's parent
# happens to BE the skadi repo, so the handbook resolves by accident. install.sh
# copies hooks/ into ~/.claude and friends, where the parent holds no handbook/
# and no previews/ — and /board and /minuial boot that copy. This section is the
# only one that exercises the path a user actually takes.
INSTALLED_ROOT="$ROOT/fake-config-root"
mkdir -p "$INSTALLED_ROOT"
cp -R "$HERE" "$INSTALLED_ROOT/hooks"
PORT2="$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")"
# The record install.sh writes, standing in for this machine's real one so the
# test proves the read path rather than whatever state $HOME happens to be in.
printf '%s\n' "$(cd "$HERE/.." && pwd)" >"$ROOT/skadi-root"
HENNETH_DIR="$ROOT/henneth" BOARD_DIR="$ROOT/installed-board" BOARD_PORT="$PORT2" \
  SKADI_ROOT_RECORD="$ROOT/skadi-root" \
  "$INSTALLED_ROOT/hooks/board.sh" serve >/dev/null 2>&1 || true

expected_installed_handbook="200"
actual_installed_handbook="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/handbook/")"
check "board.sh booted from an installed hooks dir serves the handbook" \
  "$expected_installed_handbook" "$actual_installed_handbook"

expected_installed_theme="200"
actual_installed_theme="$(curl -s -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$PORT2/previews/henneth/skadi-theme.css")"
check "and the theme its pages link" "$expected_installed_theme" "$actual_installed_theme"

# The board's own page must still come from the board dir, not the repo.
expected_installed_board="200"
actual_installed_board="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/index.html")"
check "while the board's own page still serves from the board dir" \
  "$expected_installed_board" "$actual_installed_board"

# ── 10 · a record left pointing at a repo that has moved or gone ──
# Exporting that path would name a root the server cannot serve from — no better
# than the fallback it replaces, and harder to diagnose. board.sh must refuse it,
# leaving the handbook honestly absent while the board itself carries on.
printf '%s\n' "$ROOT/no-such-repo" >"$ROOT/stale-root"
PORT3="$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")"
HENNETH_DIR="$ROOT/henneth" BOARD_DIR="$ROOT/stale-board" BOARD_PORT="$PORT3" \
  SKADI_ROOT_RECORD="$ROOT/stale-root" \
  "$INSTALLED_ROOT/hooks/board.sh" serve >/dev/null 2>&1 || true

expected_stale_handbook="404"
actual_stale_handbook="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/handbook/")"
check "a record naming a vanished repo is refused, not exported" \
  "$expected_stale_handbook" "$actual_stale_handbook"

expected_stale_board="200"
actual_stale_board="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/index.html")"
check "and the board still serves despite the stale record" \
  "$expected_stale_board" "$actual_stale_board"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
