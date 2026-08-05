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

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
