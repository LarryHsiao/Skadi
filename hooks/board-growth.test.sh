#!/bin/bash
# Offline tests for board-growth.sh. Uses the seams BOARD_GROWTH_OUT (inject
# appgrowth's stdout, skip BigQuery) and BOARD_DIR (temp folder). Run: bash board-growth.test.sh
set -uo pipefail

GROWTH="$(cd "$(dirname "$0")" && pwd)/board-growth.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

LINE="  WAU 16 (prev 17) · MAU 34 (prev 32)"

# ── 1 · a valid headline parses to the four numbers ──
d=$(tmpdir)
BOARD_DIR="$d" BOARD_GROWTH_OUT="$LINE" bash "$GROWTH" >/dev/null 2>&1
expected_nums="growth/16/17/34/32"
actual_nums=$(jq -r '"\(.channel)/\(.wau)/\(.wau_prev)/\(.mau)/\(.mau_prev)"' "$d/growth.json")
check "valid headline parses WAU/MAU + priors" "$expected_nums" "$actual_nums"

# ── 2 · a garbage headline fails loud: non-zero exit, no growth.json written ──
d=$(tmpdir)
BOARD_DIR="$d" BOARD_GROWTH_OUT="no numbers here" bash "$GROWTH" >/dev/null 2>&1
rc=$?
[[ -f "$d/growth.json" ]] && wrote="yes" || wrote="no"
expected_fail="nonzero/no"
actual_fail="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)/$wrote"
check "garbage headline fails loud, writes nothing" "$expected_fail" "$actual_fail"

# ── 3 · Enter door url is null when the door page is absent ──
d=$(tmpdir)
BOARD_DIR="$d" BOARD_GROWTH_OUT="$LINE" bash "$GROWTH" >/dev/null 2>&1
expected_nodoor="null"
actual_nodoor=$(jq -r '.url' "$d/growth.json")
check "url is null when the door page is absent" "$expected_nodoor" "$actual_nodoor"

# ── 4 · Enter door url is set when the door page is present ──
d=$(tmpdir)
echo "<html></html>" >"$d/growth-metis.html"
BOARD_DIR="$d" BOARD_GROWTH_OUT="$LINE" bash "$GROWTH" >/dev/null 2>&1
expected_door="growth-metis.html"
actual_door=$(jq -r '.url' "$d/growth.json")
check "url points at the door page when present" "$expected_door" "$actual_door"

# ── 5 · a stray non-UTF-8 byte in the output still parses (grep -a) ──
d=$(tmpdir)
stray=$(printf 'WAU 16 (prev 17) \267 MAU 34 (prev 32)')
BOARD_DIR="$d" BOARD_GROWTH_OUT="$stray" bash "$GROWTH" >/dev/null 2>&1
expected_stray="16/17/34/32"
actual_stray=$(jq -r '"\(.wau)/\(.wau_prev)/\(.mau)/\(.mau_prev)"' "$d/growth.json" 2>/dev/null)
check "stray non-UTF-8 byte still parses" "$expected_stray" "$actual_stray"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
