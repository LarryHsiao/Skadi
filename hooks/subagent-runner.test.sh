#!/usr/bin/env bash
# Exercises hooks/subagent-runner.sh against a throwaway HOME and a fake PATH,
# so a real codex on this machine never decides a verdict.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home"
mkdir -p "$TEST_HOME"
FILE="$TEST_HOME/.skadi/profiles/work/subagent-runner.md"
BIN="$TMP/bin"
mkdir -p "$BIN"

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}
# PROFILE unset means the work profile; set it (even to empty) to test another.
run() { HOME="$TEST_HOME" SKADI_PROFILE="${PROFILE-work}" PATH="$BIN:/usr/bin:/bin" "$HERE/subagent-runner.sh" "$@"; }

expected_unset="unset"
check "show reports unset before any init" "$expected_unset" "$(run show)"

expected_none_found="no runner found"
check "init writes nothing with no runner on PATH" "$expected_none_found" "$(run init 2>&1)"
check "file absent after empty init" "absent" "$([ -f "$FILE" ] && echo present || echo absent)"

printf '#!/bin/sh\nexit 0\n' > "$BIN/codex"; chmod +x "$BIN/codex"
expected_codex_line="codex exec --sandbox workspace-write -m {model} -"
run init >/dev/null
check "init writes the codex command on line 1" "$expected_codex_line" "$(head -1 "$FILE")"
check "init writes the three tier slugs" "3" "$(grep -c '^\(mechanical\|default\|strong\)=' "$FILE")"
check "show prints the file once set" "$(cat "$FILE")" "$(run show)"

expected_other_profile="unset"
check "another profile does not see the work runner" "$expected_other_profile" "$(PROFILE=personal run show)"
expected_default_path="$TEST_HOME/.skadi/profiles/default/subagent-runner.md"
PROFILE='' run init --none >/dev/null
check "an empty profile falls back to default" "present" "$([ -f "$expected_default_path" ] && echo present || echo absent)"

printf 'hand-edited\n' > "$FILE"
expected_kept="kept"
check "init never overwrites an existing file" "$expected_kept" "$(run init)"
check "hand edit survives a second init" "hand-edited" "$(cat "$FILE")"

rm -f "$FILE"
expected_none="none"
run init --none >/dev/null
check "init --none records the refusal" "$expected_none" "$(cat "$FILE")"
check "show prints none after refusal" "$expected_none" "$(run show)"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
