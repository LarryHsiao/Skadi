#!/usr/bin/env bash
# Test for handoff.sh — exercises send/read/list against a temp HANDOFF_ROOT.
# Run by hand:  hooks/handoff.test.sh   (also runnable under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/handoff.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HANDOFF_ROOT="$TMP/handoff"

fail=0
check() {
  # check <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    fail=1
  fi
}

# 1. send then read round-trips the body with from/at header.
printf 'hello world' | "$HOOK" send demo --from reviewer >/dev/null
thread="$("$HOOK" read demo)"
expected_from="from: reviewer"
check "read shows from header" "$expected_from" "$(printf '%s\n' "$thread" | grep '^from:')"
check "read shows body" "hello world" "$(printf '%s\n' "$thread" | grep 'hello world')"
check "read shows an at stamp" "1" "$(printf '%s\n' "$thread" | grep -c '^at: ')"

# 2. With no --from, the sender defaults to an 8-char session-id slice.
#    (The --from override itself is exercised by test 1, which sends as 'reviewer'.)
printf 'no flag here' | CLAUDE_CODE_SESSION_ID="0123456789abcdef" "$HOOK" send other >/dev/null
expected_default="from: 01234567"
check "default from is 8-char session slice" "$expected_default" \
  "$("$HOOK" read other | grep '^from:')"

# 3. list reports the right channel count after two channels.
expected_channels="2"
check "list shows two channels" "$expected_channels" \
  "$("$HOOK" list | grep -c '	')"
check "demo channel count is 1" "demo	1" \
  "$("$HOOK" list | grep '^demo' | cut -f1,2)"

# 4. read of a missing channel exits 0 with a notice (empty-container guard).
out="$("$HOOK" read nope)"; code=$?
check "missing channel exits 0" "0" "$code"
check "missing channel notice" "no messages in channel 'nope'" "$out"

# 5. channel name is sanitized/lowercased.
printf 'x' | "$HOOK" send "Feat/Foo Bar" >/dev/null
check "channel sanitized to lower + _" "feat_foo_bar	1" \
  "$("$HOOK" list | grep '^feat' | cut -f1,2)"

# Note: baton mode (/handoff send <channel> with no message) is the SKILL's
# job — it composes the body and pipes it to `send`, which this suite already
# covers. The composition itself is model-authored and cannot be shell-tested.

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
