#!/bin/bash
# Guards one invariant of board.sh's refresh verb: every channel writer that
# should run on a sweep is actually invoked by it.
#
# Written after board-cost.py shipped, was tested, was installed — and was never
# called. `/board refresh` completed cleanly, wrote every other channel, and left
# the spend band frozen at whatever the last manual run had produced, with
# nothing on the page to say so. The writer's own 19 tests all passed throughout:
# they proved it works, never that anything runs it.
#
# This is a source-level check, and it says so. It cannot prove the sweep
# succeeds — each writer's own test does that — only that the orchestrator still
# names it. That is the failure this file exists for, and the one the per-writer
# tests are structurally unable to see.
# Run: bash board-refresh-wiring.test.sh
set -uo pipefail

BOARD="$(cd "$(dirname "$0")" && pwd)/board.sh"
pass=0
fail=0

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# The refresh case, from its label to the next verb's — so a writer invoked
# under `serve` or `add` cannot stand in for one missing here.
refresh_case=$(awk '/^  refresh\)/{f=1} f{print} f&&/^    ;;/{exit}' "$BOARD")

# Every writer a sweep owes. A new channel writer joins this list and the
# refresh case in the same change; that pairing is the whole point.
#
# Deliberately absent: board-ticket.sh (invoked per existing channel, in a loop
# above), board-stability.py (opt-in behind --stability-scrape), and
# board-manifest.py / board-active.py / board-server.py, which are not channel
# writers at all.
for writer in board-attention.sh board-growth.sh board-cost.py \
              board-henneth.sh board-galadriel.sh; do
  expected="invoked"
  actual=$(printf '%s' "$refresh_case" | grep -q -- "$writer" && echo invoked || echo missing)
  check "refresh invokes $writer" "$expected" "$actual"
done

# A writer that fails must not abort the sweep — the other channels still owe
# their refresh, and board.sh's own convention is to note the skip and continue.
expected_guard="guarded"
actual_guard=$(printf '%s' "$refresh_case" \
  | grep -q 'board-cost.py.*||.*skipped' && echo guarded || echo unguarded)
check "a failing cost refresh is noted, not fatal" "$expected_guard" "$actual_guard"

# The loop above proves each name appears; this proves the slice it searched was
# really the refresh case and not the whole file, which would pass vacuously.
expected_scope="scoped"
actual_scope=$(printf '%s' "$refresh_case" \
  | grep -q 'board-ticket.sh' && echo scoped || echo "too-narrow")
check "the extracted slice is the refresh case, not an empty read" "$expected_scope" "$actual_scope"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
