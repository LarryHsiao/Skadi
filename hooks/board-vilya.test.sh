#!/bin/bash
# Offline tests for board-vilya.sh. Uses the seams SKADI_VILYA_ROOT (where
# vilya.sh keeps its state) and BOARD_DIR (temp folder), and stands real
# background processes in for live and dead servers.
# Run: bash board-vilya.test.sh
set -uo pipefail

VILYA="$(cd "$(dirname "$0")" && pwd)/board-vilya.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
PIDS=()
cleanup() {
  [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# A process that stays alive until the trap reaps it. Sets LIVE.
spawn_live() { sleep 300 >/dev/null 2>&1 & LIVE=$!; PIDS+=("$LIVE"); }

# A pid that has exited, so kill -0 fails on it. Sets DEAD.
spawn_dead() { true & DEAD=$!; wait "$DEAD" 2>/dev/null; }

# Lays one server slot the way vilya.sh does: <root>/<proj>-<sum>/<name>/
# holding pid, log and meta. Args: root project-path name pid [log-line]
lay_server() {
  local dir
  dir="$1/$(basename "$2")-1234/$3"
  mkdir -p "$dir"
  echo "$4" >"$dir/pid"
  echo "${5:-}" >"$dir/log"
  { echo "project=$2"; echo "name=$3"; echo "command=serve"; } >"$dir/meta"
}

run() { BOARD_DIR="$1" SKADI_VILYA_ROOT="$2" bash "$VILYA" >/dev/null 2>&1; }

# ── 1 · no server state at all → channel with an empty list ──
b=$(tmpdir); r=$(tmpdir)
run "$b" "$r"
expected_empty='{"channel":"vilya","count":0}'
actual_empty=$(jq -c '{channel, count: (.servers | length)}' "$b/vilya.json")
check "no state writes an empty vilya channel" "$expected_empty" "$actual_empty"

# ── 2 · one live server whose log names its address → one alive row ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_server "$r" /home/me/work/Blog zola "$pid" "Web server is available at http://127.0.0.1:1111/ (bound)"
run "$b" "$r"
expected_alive="{\"project\":\"Blog\",\"name\":\"zola\",\"url\":\"http://127.0.0.1:1111/\",\"state\":\"alive\",\"pid\":$pid}"
actual_alive=$(jq -c '.servers[0]' "$b/vilya.json")
check "a live server reads alive with the url its log printed" "$expected_alive" "$actual_alive"

# ── 3 · a live server that printed no address → url null ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_server "$r" /home/me/work/api mock "$pid" "listening"
run "$b" "$r"
expected_nourl='{"state":"alive","url":null}'
actual_nourl=$(jq -c '.servers[0] | {state, url}' "$b/vilya.json")
check "a server with no address in its log has a null url" "$expected_nourl" "$actual_nourl"

# ── 4 · a dead pid with a fresh log → a dead row, kept so the loss is seen ──
b=$(tmpdir); r=$(tmpdir)
spawn_dead
lay_server "$r" /home/me/work/api mock "$DEAD" "crashed"
run "$b" "$r"
expected_dead='{"state":"dead","project":"api"}'
actual_dead=$(jq -c '.servers[0] | {state, project}' "$b/vilya.json")
check "a recently-dead server reads dead" "$expected_dead" "$actual_dead"

# ── 5 · a dead pid whose log is days old → omitted (the 24 h cap) ──
b=$(tmpdir); r=$(tmpdir)
spawn_dead
lay_server "$r" /home/me/work/api mock "$DEAD" "crashed"
touch -t 202001010000 "$r"/api-1234/mock/log
run "$b" "$r"
expected_stale=0
actual_stale=$(jq '.servers | length' "$b/vilya.json")
check "a long-dead server is dropped from the band" "$expected_stale" "$actual_stale"

# ── 6 · two servers of one project → two rows ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; p1=$LIVE
spawn_live; p2=$LIVE
lay_server "$r" /home/me/work/shop web "$p1" "Local: http://localhost:5173/"
lay_server "$r" /home/me/work/shop mock "$p2" "Serving HTTP on 0.0.0.0 port 8000"
run "$b" "$r"
expected_two='["mock","web"]'
actual_two=$(jq -c '[.servers[].name] | sort' "$b/vilya.json")
check "two servers of one project give two rows" "$expected_two" "$actual_two"

# ── 7 · a damaged slot must not take the healthy ones down with it ──
# A garbage pid file and a slot with no pid file at all.
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_server "$r" /home/me/work/aaa-broken junk "not-a-pid"
mkdir -p "$r/bbb-1234/no-pid" && : >"$r/bbb-1234/no-pid/log"
lay_server "$r" /home/me/work/zzz-healthy web "$pid" "http://localhost:1/"
BOARD_DIR="$b" SKADI_VILYA_ROOT="$r" bash "$VILYA" >/dev/null 2>&1
check "a damaged slot does not abort the writer" "0" "$?"
expected_healthy="zzz-healthy"
actual_healthy=$(jq -r '[.servers[] | select(.name == "web")][0].project' "$b/vilya.json")
check "the healthy server's row survives the damaged ones" "$expected_healthy" "$actual_healthy"

# ── 8 · a writer that fails midway must not leave a false channel behind ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_server "$r" /home/me/work/shop web "$pid" "http://localhost:1/"
run "$b" "$r"
expected_kept=1
shim=$(tmpdir)
printf '#!/bin/bash\nexit 1\n' >"$shim/jq" && chmod +x "$shim/jq"
PATH="$shim:$PATH" BOARD_DIR="$b" SKADI_VILYA_ROOT="$r" bash "$VILYA" >/dev/null 2>&1
failed=$?
check "a failing run exits nonzero" "1" "$([[ "$failed" -ne 0 ]] && echo 1 || echo 0)"
actual_kept=$(jq '.servers | length' "$b/vilya.json")
check "the earlier good channel survives the failed run whole" "$expected_kept" "$actual_kept"

# ── 9 · the channel carries an `updated` stamp, so the page re-renders on a change ──
# The page re-renders only when a channel's id:updated signature moves.
b=$(tmpdir); r=$(tmpdir)
run "$b" "$r"
expected_stamp="stamped"
actual_stamp=$(jq -r 'if (.updated // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then "stamped" else "bare" end' "$b/vilya.json")
check "the channel bears an ISO updated stamp" "$expected_stamp" "$actual_stamp"

# ── 10 · a url stored in meta outranks the one the log printed ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_server "$r" /home/me/work/Blog zola "$pid" "Web server is available at http://127.0.0.1:1111/"
echo "url=https://blog.test/" >>"$r/Blog-1234/zola/meta"
run "$b" "$r"
expected_stored="https://blog.test/"
actual_stored=$(jq -r '.servers[0].url' "$b/vilya.json")
check "a stored url outranks the log-derived one" "$expected_stored" "$actual_stored"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
