#!/usr/bin/env bash
# Test for ping-pong.sh — the UserPromptSubmit bare-"ping" hook.
# Run by hand:  hooks/ping-pong.test.sh   (also runnable under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/ping-pong.sh"

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

ctx_of() {
  # ctx_of <prompt> — the additionalContext the hook emits for that prompt
  jq -n --arg p "$1" '{prompt: $p}' | "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}

# 1. A bare "ping" announces itself as UserPromptSubmit context.
expected_event="UserPromptSubmit"
check "emits UserPromptSubmit additionalContext" "$expected_event" \
  "$(jq -n '{prompt: "ping"}' | "$HOOK" 2>/dev/null \
     | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null || true)"

# 2. Case and surrounding whitespace do not hide a ping.
expected_present="present"
check "an upper-case, padded ping still fires" "$expected_present" \
  "$(if [ -n "$(ctx_of '  PING  ')" ]; then echo present; else echo absent; fi)"

# 3. Anything else is not a ping — the hook stays silent rather than gagging a
#    real turn into a one-word reply.
expected_silent=""
check "a longer prompt emits nothing" "$expected_silent" "$(ctx_of 'ping the server')"
check "an empty prompt emits nothing" "$expected_silent" "$(ctx_of '')"

# 4. The context still calls for the one-word reply.
expected_pong="pong"
check "the context names the pong reply" "$expected_pong" \
  "$(ctx_of 'ping' | grep -o 'pong' | head -1 || true)"

# 5. The context yields to handoff messages. Without this proviso the poll's
#    auto-pickup is read, the cursor advances, and the baton is buried under a
#    bare "pong" — it will not surface again on the next turn.
expected_handoff="handoff"
check "the context carries the handoff proviso" "$expected_handoff" \
  "$(ctx_of 'ping' | grep -o -i 'handoff' | head -1 | tr '[:upper:]' '[:lower:]' || true)"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
