#!/bin/bash
# Offline tests for board-galadriel.sh. Uses the seams BOARD_GALADRIEL_PORT (inject
# the port), GALADRIEL_DIR (where the lockfile is read), and BOARD_DIR (temp folder).
# A throwaway http.server stands in for a live Galadriel. Run: bash board-galadriel.test.sh
set -uo pipefail

GALADRIEL="$(cd "$(dirname "$0")" && pwd)/board-galadriel.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · a live server → its url is written ──
d=$(tmpdir)
srv=$(tmpdir)
echo '{"projects":[]}' >"$srv/index.json"
sport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$sport" --bind 127.0.0.1 --directory "$srv" >/dev/null 2>&1 &
srvpid=$!
for _ in $(seq 1 20); do curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$sport/index.json" && break; sleep 0.2; done
BOARD_DIR="$d" BOARD_GALADRIEL_PORT="$sport" bash "$GALADRIEL" >/dev/null 2>&1
kill "$srvpid" 2>/dev/null
expected_live="http://localhost:$sport/"
actual_live=$(jq -r '.url' "$d/galadriel.json")
check "live server writes its url" "$expected_live" "$actual_live"

# ── 2 · a port that answers nothing → url null ──
# The reason the hook probes rather than trusting the lockfile: a killed server
# leaves its port file behind, and a board button pointing at nothing is worse
# than no button.
d=$(tmpdir)
dead=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
BOARD_DIR="$d" BOARD_GALADRIEL_PORT="$dead" bash "$GALADRIEL" >/dev/null 2>&1
expected_dead="null"
actual_dead=$(jq -r '.url' "$d/galadriel.json")
check "dead port writes null" "$expected_dead" "$actual_dead"

# ── 3 · no lockfile, no injected port → url null ──
d=$(tmpdir)
empty=$(tmpdir)
BOARD_DIR="$d" GALADRIEL_DIR="$empty" bash "$GALADRIEL" >/dev/null 2>&1
expected_none="null"
actual_none=$(jq -r '.url' "$d/galadriel.json")
check "no port at all writes null" "$expected_none" "$actual_none"

# ── 4 · a stale lockfile is read, then disbelieved ──
d=$(tmpdir)
lock=$(tmpdir)
stale=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
printf '%s\n' "$stale" >"$lock/.galadriel-port"
BOARD_DIR="$d" GALADRIEL_DIR="$lock" bash "$GALADRIEL" >/dev/null 2>&1
expected_stale="null"
actual_stale=$(jq -r '.url' "$d/galadriel.json")
check "stale lockfile writes null" "$expected_stale" "$actual_stale"

# ── a port that accepts but never answers → url null, and promptly ──
# A held-open connection (or a firewall that drops instead of refusing) must not
# hang the probe: the board's serve path waits on this hook.
d=$(tmpdir)
silent=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -c 'import socket,sys,time;s=socket.socket();s.bind(("127.0.0.1",int(sys.argv[1])));s.listen(8);time.sleep(60)' "$silent" &
silentpid=$!
# Wait until the listener accepts, or the probe below would meet a closed
# port and pass without ever testing the silent case.
for _ in $(seq 1 30); do timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$silent" 2>/dev/null && break; sleep 0.1; done
BOARD_DIR="$d" BOARD_GALADRIEL_PORT="$silent" timeout 15 bash "$GALADRIEL" >/dev/null 2>&1
kill "$silentpid" 2>/dev/null
expected_silent="null"
actual_silent=$(jq -r '.url' "$d/galadriel.json" 2>/dev/null)
check "silent port writes null without hanging" "$expected_silent" "$actual_silent"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
