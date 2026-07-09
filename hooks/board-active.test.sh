#!/bin/bash
# Offline tests for board-active.py. Builds a board of plain ticket channels in a
# temp folder (no tracker fetch), flips the hero, and reads back the active flags.
# Run: bash board-active.test.sh
set -uo pipefail

FLIP="$(cd "$(dirname "$0")" && pwd)/board-active.py"
pass=0
fail=0

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

# A minimal ticket channel with the given key and active flag.
write_ticket() { # dir key active
  cat >"$1/ticket-$2.json" <<JSON
{"channel":"ticket","id":"$2","title":"t $2","active":$3}
JSON
}

# ── 1 · flip promotes the target and clears the reigning hero ──
d="$ROOT/one"; mkdir -p "$d"
write_ticket "$d" AAA-1 true
write_ticket "$d" AAA-2 false
python3 "$FLIP" "$d" AAA-2 >/dev/null 2>&1
expected_flip="false/true"
actual_flip="$(jq -r '.active' "$d/ticket-AAA-1.json")/$(jq -r '.active' "$d/ticket-AAA-2.json")"
check "flip clears the old hero and raises the new" "$expected_flip" "$actual_flip"

# ── 2 · exactly one hero across three tickets ──
d="$ROOT/three"; mkdir -p "$d"
write_ticket "$d" BBB-1 true
write_ticket "$d" BBB-2 false
write_ticket "$d" BBB-3 false
python3 "$FLIP" "$d" BBB-3 >/dev/null 2>&1
expected_count="1"
actual_count="$(grep -l '"active":true\|"active": true' "$d"/ticket-*.json | wc -l | tr -d ' ')"
check "exactly one hero stands after the flip" "$expected_count" "$actual_count"

# ── 3 · an unchanged file keeps its mtime (only two files ever churn) ──
d="$ROOT/mtime"; mkdir -p "$d"
write_ticket "$d" CCC-1 true
write_ticket "$d" CCC-2 false
write_ticket "$d" CCC-3 false   # bystander — neither promoted nor deposed
before=$(stat -f %m "$d/ticket-CCC-3.json" 2>/dev/null || stat -c %Y "$d/ticket-CCC-3.json")
sleep 1
python3 "$FLIP" "$d" CCC-2 >/dev/null 2>&1
after=$(stat -f %m "$d/ticket-CCC-3.json" 2>/dev/null || stat -c %Y "$d/ticket-CCC-3.json")
expected_mtime="same"
actual_mtime=$([[ "$before" == "$after" ]] && echo same || echo changed)
check "a bystander ticket is left untouched" "$expected_mtime" "$actual_mtime"

# ── 4 · a missing target throws, touches nothing ──
d="$ROOT/missing"; mkdir -p "$d"
write_ticket "$d" DDD-1 true
python3 "$FLIP" "$d" DDD-9 >/dev/null 2>&1
rc=$?
expected_missing="1/true"
actual_missing="$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)/$(jq -r '.active' "$d/ticket-DDD-1.json")"
check "missing target exits non-zero and leaves the hero as-was" "$expected_missing" "$actual_missing"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
