#!/bin/bash
# Offline tests for board-narya.sh. Uses the seams SKADI_FLUTTER_ROOT (where the
# daemon keeps its state) and BOARD_DIR (temp folder), and stands real
# background processes in for live and dead daemons.
# Run: bash board-narya.test.sh
set -uo pipefail

NARYA="$(cd "$(dirname "$0")" && pwd)/board-narya.sh"
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

# A process that stays alive until the trap reaps it. Sets LIVE rather than
# printing, so the array is updated in this shell and no pipe is held open.
spawn_live() { sleep 300 >/dev/null 2>&1 & LIVE=$!; PIDS+=("$LIVE"); }

# A pid that has exited, so kill -0 fails on it. Sets DEAD.
spawn_dead() { true & DEAD=$!; wait "$DEAD" 2>/dev/null; }

# Lays one daemon slot the way flutter-daemon.sh does: <root>/<proj>-<sum>/<slug>/
# holding log, daemon.pid and meta. Args: root proj-dir slug device pid [appId]
lay_daemon() {
  local dir
  dir="$1/$(basename "$2")-1234/$3"
  mkdir -p "$dir"
  : >"$dir/log"
  echo "$5" >"$dir/daemon.pid"
  { echo "project=$2"; echo "device=$4"; [[ -n "${6:-}" ]] && echo "appId=$6"; } >"$dir/meta"
}

run() { BOARD_DIR="$1" SKADI_FLUTTER_ROOT="$2" bash "$NARYA" >/dev/null 2>&1; }

# ── 1 · no daemon state at all → channel with an empty list ──
b=$(tmpdir); r=$(tmpdir)
run "$b" "$r"
expected_empty='{"channel":"narya","count":0}'
actual_empty=$(jq -c '{channel, count: (.daemons | length)}' "$b/narya.json")
check "no state writes an empty narya channel" "$expected_empty" "$actual_empty"

# ── 2 · one live daemon with an appId → one alive row ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_daemon "$r" /home/me/work/vitallink-ca default-slot "iPhone-16" "$pid" com.example.app
run "$b" "$r"
expected_alive="{\"project\":\"vitallink-ca\",\"device\":\"iPhone-16\",\"state\":\"alive\",\"appId\":\"com.example.app\",\"pid\":$pid}"
actual_alive=$(jq -c '.daemons[0]' "$b/narya.json")
check "a live daemon reads alive, project shown by basename" "$expected_alive" "$actual_alive"

# ── 3 · a live daemon with no appId yet → starting, appId null ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_daemon "$r" /home/me/work/metis default-slot "iPad-Air" "$pid"
run "$b" "$r"
expected_starting='{"state":"starting","appId":null}'
actual_starting=$(jq -c '.daemons[0] | {state, appId}' "$b/narya.json")
check "a live daemon before app.started reads starting with a null appId" "$expected_starting" "$actual_starting"

# ── 4 · a dead pid with a fresh log → a dead row, kept so the loss is seen ──
b=$(tmpdir); r=$(tmpdir)
spawn_dead
lay_daemon "$r" /home/me/work/metis default-slot "iPad-Air" "$DEAD" com.example.app
run "$b" "$r"
expected_dead='{"state":"dead","project":"metis"}'
actual_dead=$(jq -c '.daemons[0] | {state, project}' "$b/narya.json")
check "a recently-dead daemon reads dead" "$expected_dead" "$actual_dead"

# ── 5 · a dead pid whose log is days old → omitted, not shown forever ──
b=$(tmpdir); r=$(tmpdir)
spawn_dead
lay_daemon "$r" /home/me/work/metis default-slot "iPad-Air" "$DEAD" com.example.app
touch -t 202001010000 "$r"/metis-1234/default-slot/log
run "$b" "$r"
expected_stale=0
actual_stale=$(jq '.daemons | length' "$b/narya.json")
check "a long-dead daemon is dropped from the band" "$expected_stale" "$actual_stale"

# ── 6 · two devices for one project → two rows ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; p1=$LIVE
spawn_live; p2=$LIVE
lay_daemon "$r" /home/me/work/vitallink-ca slot-a "iPhone-16" "$p1" app.a
lay_daemon "$r" /home/me/work/vitallink-ca slot-b "Pixel-8" "$p2" app.b
run "$b" "$r"
expected_two='["iPhone-16","Pixel-8"]'
actual_two=$(jq -c '[.daemons[].device]' "$b/narya.json")
check "two devices of one project give two rows" "$expected_two" "$actual_two"

# ── 7 · one damaged slot must not take the healthy ones down with it ──
# Damaged three ways: a garbage daemon.pid, a slot with a log but no daemon.pid
# at all, and a missing meta (flutter-daemon.sh writes daemon.pid before meta,
# so a start caught mid-way leaves exactly that). The healthy daemon still shows.
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_daemon "$r" /home/me/work/aaa-broken garbage "x" "not-a-pid"
mkdir -p "$r/bbb-1234/no-pid" && : >"$r/bbb-1234/no-pid/log"
mkdir -p "$r/ccc-1234/no-meta" && : >"$r/ccc-1234/no-meta/log" && echo "$pid" >"$r/ccc-1234/no-meta/daemon.pid"
lay_daemon "$r" /home/me/work/zzz-healthy slot "iPhone-16" "$pid" app.z
BOARD_DIR="$b" SKADI_FLUTTER_ROOT="$r" bash "$NARYA" >/dev/null 2>&1
actual_status=$?
expected_status=0
check "a damaged slot does not abort the writer" "$expected_status" "$actual_status"
expected_healthy="zzz-healthy"
actual_healthy=$(jq -r '[.daemons[] | select(.appId == "app.z")][0].project' "$b/narya.json")
check "the healthy daemon's row survives the damaged ones" "$expected_healthy" "$actual_healthy"

# ── 8 · a writer that fails midway must not leave a false channel behind ──
# A jq that always fails stands in for any mid-run failure. The earlier good
# channel must survive it whole — a truncated or blank file would read to the
# board as "no daemon stands".
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
lay_daemon "$r" /home/me/work/metis slot "iPad-Air" "$pid" app.m
run "$b" "$r"
expected_kept=1
shim=$(tmpdir)
printf '#!/bin/bash\nexit 1\n' >"$shim/jq" && chmod +x "$shim/jq"
PATH="$shim:$PATH" BOARD_DIR="$b" SKADI_FLUTTER_ROOT="$r" bash "$NARYA" >/dev/null 2>&1
failed=$?
check "a failing run exits nonzero" "1" "$([[ "$failed" -ne 0 ]] && echo 1 || echo 0)"
actual_kept=$(jq '.daemons | length' "$b/narya.json")
check "the earlier good channel survives the failed run whole" "$expected_kept" "$actual_kept"

# ── 9 · a missing meta falls back to the slot's project directory name ──
b=$(tmpdir); r=$(tmpdir)
spawn_live; pid=$LIVE
mkdir -p "$r/vitallink-ca-1039889385/slot" && : >"$r/vitallink-ca-1039889385/slot/log" && echo "$pid" >"$r/vitallink-ca-1039889385/slot/daemon.pid"
run "$b" "$r"
expected_fallback="vitallink-ca"
actual_fallback=$(jq -r '.daemons[0].project' "$b/narya.json")
check "a row with no meta is named after its state directory, not blank" "$expected_fallback" "$actual_fallback"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
