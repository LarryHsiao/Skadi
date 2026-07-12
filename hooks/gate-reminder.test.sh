#!/bin/bash
# Offline tests for the free-form gate reminder hook. The contract: the hook
# emits valid UserPromptSubmit JSON whose reminder carries the exact tokens the
# pulse scorer (pulse-rubric.json) measures — "Size ▰" and "Acceptance".
# Run: bash gate-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/gate-reminder.sh"
RUBRIC="$HERE/pulse-rubric.json"
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

# ── 2 · the reminder carries every token the pulse scorer matches ──
# NB: hook output lands in a temp file, not a pipe — `python3 -` reads its
# script from stdin, so piping the JSON there too would starve one of them.
expected_tokens="sizing:yes acceptance:yes"
hook_out="$(mktemp)"
bash "$HOOK" > "$hook_out"
actual_tokens=$(python3 - "$RUBRIC" "$hook_out" <<'PY'
import json, re, sys
ctx = json.load(open(sys.argv[2], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
rubric = {r["id"]: r for r in json.load(open(sys.argv[1], encoding="utf-8"))}
sizing = bool(re.search(rubric["rule.task-sizing"]["complied"], ctx))
acceptance = bool(re.search(rubric["rule.acceptance"]["complied"], ctx))
print("sizing:%s acceptance:%s" % ("yes" if sizing else "no", "yes" if acceptance else "no"))
PY
)
rm -f "$hook_out"
check "reminder carries the scorer's sizing and acceptance tokens" "$expected_tokens" "$actual_tokens"

# ── 3 · the reminder names its own exemptions, so it cannot misfire on skill runs ──
expected_exempt="yes"
actual_exempt=$(bash "$HOOK" | python3 -c "
import json, sys
ctx = json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
print('yes' if 'slash-invoked skills' in ctx and 'read-only' in ctx else 'no')
")
check "reminder exempts read-only turns and slash-invoked skills" "$expected_exempt" "$actual_exempt"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
