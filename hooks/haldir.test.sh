#!/bin/bash
# Offline smoke tests for the haldir.sh launch script. haldir.sh spawns real
# background `claude` sessions, so these tests never execute it — they check
# syntax validity and that the launch prompt carries every phrase the spawned
# session depends on (channel read+clear, and the never-self-stop override).
# Run: bash haldir.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/haldir.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the script is syntactically valid ──
expected_syntax="ok"
actual_syntax=$(bash -n "$HOOK" 2>&1 && echo ok || echo "FAIL")
check "haldir.sh is syntactically valid" "$expected_syntax" "$actual_syntax"

# ── 2 · the launch prompt has the spawned session read, act on, then clear its channel ──
expected_cleanup="yes"
actual_cleanup=$(grep -q '/handoff read \$name' "$HOOK" && grep -q '/handoff clear \$name' "$HOOK" && echo yes || echo no)
check "launch prompt reads and clears the channel" "$expected_cleanup" "$actual_cleanup"

# ── 3 · the clear step is explicitly unattended (no confirm) ──
expected_noconfirm="yes"
actual_noconfirm=$(grep -q 'no need to confirm' "$HOOK" && echo yes || echo no)
check "clear step is explicitly unattended" "$expected_noconfirm" "$actual_noconfirm"

# ── 4 · the launch prompt tells the spawned session never to self-stop on quiet ticks ──
expected_neverstop="yes"
actual_neverstop=$(grep -q 'Never self-stop the loop on quiet ticks' "$HOOK" && echo yes || echo no)
check "launch prompt overrides the default quiet-tick self-stop" "$expected_neverstop" "$actual_neverstop"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
