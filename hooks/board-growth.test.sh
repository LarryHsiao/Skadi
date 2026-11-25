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

# ── multi-app: GROWTH_APPS_FILE lists apps; BOARD_GROWTH_OUT_<APP> injects one app's output ──
TAB=$'\t'
METIS_LINE="  WAU 3 (prev 12) · MAU 15 (prev 17)"
SNOTRA_LINE="  WAU 5 (prev 4) · MAU 20 (prev 18)"

# ── 6 · no apps file keeps the single-metis shape, not partial ──
d=$(tmpdir)
GROWTH_APPS_FILE="$d/absent.tsv" BOARD_DIR="$d" BOARD_GROWTH_OUT="$METIS_LINE" bash "$GROWTH" >/dev/null 2>&1
expected_default="metis/3/false"
actual_default=$(jq -r '"\(.apps | map(.app) | join(","))/\(.wau)/\(.partial)"' "$d/growth.json")
check "no apps file reads as metis alone, not partial" "$expected_default" "$actual_default"

# ── 7 · two apps with data: totals are the sums, the split is listed ──
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%sp2%sd2\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" \
  BOARD_GROWTH_OUT_METIS="$METIS_LINE" BOARD_GROWTH_OUT_SNOTRA="$SNOTRA_LINE" bash "$GROWTH" >/dev/null 2>&1
expected_sum="8/16/35/false/metis=3,snotra=5"
actual_sum=$(jq -r '"\(.wau)/\(.wau_prev)/\(.mau)/\(.partial)/\(.apps | map("\(.app)=\(.wau)") | join(","))"' "$d/growth.json")
check "two apps sum into the totals and list the split" "$expected_sum" "$actual_sum"

# ── 8 · a dataset of '-' means no export: partial, totals are the other app's, never a zero ──
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%ssnotra-crm%s-\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" BOARD_GROWTH_OUT_METIS="$METIS_LINE" bash "$GROWTH" >/dev/null 2>&1
expected_noexp="3/true/null/no export"
actual_noexp=$(jq -r '"\(.wau)/\(.partial)/\(.apps[1].wau)/\(.apps[1].note)"' "$d/growth.json")
check "no-export app is partial and null, not zero" "$expected_noexp" "$actual_noexp"

# ── 9 · one app's output unparseable: the other still lands, run still succeeds ──
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%sp2%sd2\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" \
  BOARD_GROWTH_OUT_METIS="$METIS_LINE" BOARD_GROWTH_OUT_SNOTRA="garbage" bash "$GROWTH" >/dev/null 2>&1
rc=$?
expected_one="0/3/true/null"
actual_one="$rc/$(jq -r '"\(.wau)/\(.partial)/\(.apps[1].wau)"' "$d/growth.json")"
check "an unparseable app leaves the other on the board" "$expected_one" "$actual_one"

# ── 10 · a missing appgrowth fails that app alone, the injected one still lands ──
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%sp2%sd2\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
mkdir -p "$d/emptyhome"
HOME="$d/emptyhome" GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" \
  BOARD_GROWTH_OUT_METIS="$METIS_LINE" bash "$GROWTH" >/dev/null 2>&1
rc=$?
expected_missing="0/3/true/query failed: cannot run appgrowth"
actual_missing="$rc/$(jq -r '"\(.wau)/\(.partial)/\(.apps[1].note | .[0:34])"' "$d/growth.json" 2>/dev/null)"
check "a missing appgrowth fails that app alone" "$expected_missing" "$actual_missing"

# ── 11 · board.sh list shows the split for two apps, and the old line for one ──
BOARD="$(cd "$(dirname "$GROWTH")" && pwd)/board.sh"
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%sp2%sd2\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" \
  BOARD_GROWTH_OUT_METIS="$METIS_LINE" BOARD_GROWTH_OUT_SNOTRA="$SNOTRA_LINE" bash "$GROWTH" >/dev/null 2>&1
expected_list="metis + snotra WAU 8 · MAU 35 [metis 3 · snotra 5]"
actual_list=$(BOARD_DIR="$d" bash "$BOARD" list 2>&1 | grep "WAU" | sed 's/^ *//; s/  */ /g')
check "list shows the split for two apps" "$expected_list" "$actual_list"

d=$(tmpdir)
GROWTH_APPS_FILE="$d/absent.tsv" BOARD_DIR="$d" BOARD_GROWTH_OUT="$METIS_LINE" bash "$GROWTH" >/dev/null 2>&1
expected_list1="metis WAU 3 · MAU 15"
actual_list1=$(BOARD_DIR="$d" bash "$BOARD" list 2>&1 | grep "WAU" | sed 's/^ *//; s/  */ /g')
check "list keeps the single-app line unchanged" "$expected_list1" "$actual_list1"

# ── 12 · every app without numbers fails loud and writes nothing ──
d=$(tmpdir)
printf 'metis%s%s%s\nsnotra%ssnotra-crm%s-\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$d/apps.tsv"
GROWTH_APPS_FILE="$d/apps.tsv" BOARD_DIR="$d" BOARD_GROWTH_OUT_METIS="garbage" bash "$GROWTH" >/dev/null 2>&1
rc=$?
[[ -f "$d/growth.json" ]] && wrote="yes" || wrote="no"
expected_none="nonzero/no"
actual_none="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)/$wrote"
check "no app with numbers fails loud, writes nothing" "$expected_none" "$actual_none"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
