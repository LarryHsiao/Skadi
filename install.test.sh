#!/bin/bash
# Offline tests for install.sh's global CLAUDE.md choice. The contract: the
# default root (~/.claude) takes the one-line stub only when a profile root
# actually stands beside it. Claude Code loads ~/.claude/CLAUDE.md as a baseline
# alongside whichever profile is active, so on a two-root machine the full file
# would arrive twice in one context window — that is what the stub cures. On a
# single-root machine ~/.claude *is* the active root, and stubbing it would
# leave the global rules nowhere at all.
# Run: bash install.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install.sh"
FULL="$HERE/CLAUDE.md"
STUB="$HERE/CLAUDE.stub.md"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Which of the two sources landed at the given path. The whole file is compared,
# not its first line, so a reworded stub cannot quietly pass for the full text.
which_claude_md() { # path
  if cmp -s "$1" "$FULL"; then echo "full"
  elif cmp -s "$1" "$STUB"; then echo "stub"
  else echo "neither"; fi
}

# Each case drives the real script against its own throwaway HOME, so a profile
# root one case creates cannot be seen by another. ~19s per run on Windows;
# three runs is the price of testing install.sh itself rather than a copy of its
# condition, which would pass while the script stayed broken.
run_install() { # home root
  HOME="$1" bash "$INSTALL" "$2" >/dev/null 2>&1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1 · single-root machine: the default root carries the full rules ──
expected_alone="full"
mkdir -p "$TMP/alone/.claude"
run_install "$TMP/alone" "$TMP/alone/.claude"
actual_alone="$(which_claude_md "$TMP/alone/.claude/CLAUDE.md")"
check "default root alone takes the full CLAUDE.md" "$expected_alone" "$actual_alone"

# ── 2 · a profile root stands beside it: the default root steps aside ──
expected_beside="stub"
mkdir -p "$TMP/beside/.claude" "$TMP/beside/.claude-personal"
run_install "$TMP/beside" "$TMP/beside/.claude"
actual_beside="$(which_claude_md "$TMP/beside/.claude/CLAUDE.md")"
check "default root beside a profile root takes the stub" "$expected_beside" "$actual_beside"

# ── 3 · the profile root itself always carries the full rules ──
expected_profile="full"
mkdir -p "$TMP/profile/.claude-personal"
run_install "$TMP/profile" "$TMP/profile/.claude-personal"
actual_profile="$(which_claude_md "$TMP/profile/.claude-personal/CLAUDE.md")"
check "profile root takes the full CLAUDE.md" "$expected_profile" "$actual_profile"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
