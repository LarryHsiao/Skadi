#!/bin/bash
# Offline tests for board-sweep.sh. Uses BOARD_DIR (temp folder) — no live sweep
# is run; the recorder is fed a verdict directly. Run: bash board-sweep.test.sh
set -uo pipefail

SWEEP="$(cd "$(dirname "$0")" && pwd)/board-sweep.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · a valid verdict is recorded as a sweep channel ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$SWEEP" glorfindel stirred "3 planned · next 12:34" >/dev/null 2>&1
expected="sweep/glorfindel/stirred/3 planned · next 12:34"
actual=$(jq -r '"\(.channel)/\(.name)/\(.verdict)/\(.detail)"' "$d/sweep-glorfindel.json")
check "records channel/name/verdict/detail" "$expected" "$actual"

# ── 2 · the sweep channel joins the manifest ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$SWEEP" moria mend "2 open" >/dev/null 2>&1
expected_man="yes"
actual_man=$(jq -e '.channels | index("sweep-moria.json") != null' "$d/channels.json" >/dev/null 2>&1 && echo yes || echo no)
check "sweep channel appears in the manifest" "$expected_man" "$actual_man"

# ── 3 · an unknown verdict fails loud, writes nothing ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$SWEEP" aule sideways "detail" >/dev/null 2>&1
rc=$?
[[ -f "$d/sweep-aule.json" ]] && wrote="yes" || wrote="no"
expected_bad="nonzero/no"
actual_bad="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)/$wrote"
check "unknown verdict fails loud, writes nothing" "$expected_bad" "$actual_bad"

# ── 4 · missing args fails loud ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$SWEEP" glorfindel >/dev/null 2>&1
rc=$?
expected_usage="nonzero"
actual_usage="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "missing verdict fails loud" "$expected_usage" "$actual_usage"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
