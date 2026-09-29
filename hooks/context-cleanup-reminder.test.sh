#!/bin/bash
# Offline tests for the context-cleanup reminder hook. The contract: the hook
# emits valid UserPromptSubmit JSON whose reminder names the /clear ask, the
# "concluded" condition that gates it, and the skip cases that keep it from
# misfiring mid-task.
# Run: bash context-cleanup-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/context-cleanup-reminder.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the hook emits valid JSON shaped for UserPromptSubmit ──
expected_shape="UserPromptSubmit/yes"
actual_shape=$(bash "$HOOK" | python3 -c "
import json, sys
d = json.load(sys.stdin)
out = d['hookSpecificOutput']
print('%s/%s' % (out['hookEventName'], 'yes' if out.get('additionalContext') else 'no'))
")
check "hook emits valid UserPromptSubmit JSON with context" "$expected_shape" "$actual_shape"

# ── 2 · the reminder names the /clear ask ──
expected_ask="yes"
actual_ask=$(bash "$HOOK" | python3 -c "
import json, sys
ctx = json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
print('yes' if '/clear' in ctx else 'no')
")
check "reminder names the /clear ask" "$expected_ask" "$actual_ask"

# ── 3 · the reminder never authorizes running /clear unprompted ──
expected_unprompted="yes"
actual_unprompted=$(bash "$HOOK" | python3 -c "
import json, sys
ctx = json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
print('yes' if 'never run it unprompted' in ctx else 'no')
")
check "reminder forbids running /clear unprompted" "$expected_unprompted" "$actual_unprompted"

# ── 4 · the reminder names its skip conditions, so it cannot misfire mid-task ──
expected_skip="yes"
actual_skip=$(bash "$HOOK" | python3 -c "
import json, sys
ctx = json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
print('yes' if 'mid-task' in ctx and 'same thread' in ctx else 'no')
")
check "reminder skips mid-task and same-thread turns" "$expected_skip" "$actual_skip"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
