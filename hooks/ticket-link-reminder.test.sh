#!/bin/bash
# Offline test for the ticket-key link reminder hook. The contract: valid
# UserPromptSubmit JSON whose reminder carries the link form, both tracker URL
# shapes, the plain-text exceptions, and the instruction not to mention it.
# Run: bash ticket-link-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/ticket-link-reminder.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ctx_has <needle>... — prints yes/no per needle, space-joined, from the hook's context.
ctx_has() {
  python3 - "$hook_out" "$@" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print(" ".join("yes" if n in ctx else "no" for n in sys.argv[2:]))
PY
}

hook_out="$(mktemp)"
bash "$HOOK" > "$hook_out"

expected_shape="UserPromptSubmit"
actual_shape=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['hookSpecificOutput']['hookEventName'])" "$hook_out")
check "hook emits valid UserPromptSubmit JSON" "$expected_shape" "$actual_shape"

check "reminder shows the markdown link form" "yes" "$(ctx_has '[PSG-4000](url)')"
check "reminder names both tracker URL shapes" "yes yes" "$(ctx_has '<base>/browse/<KEY>' '<base>/issue/<KEY>')"
check "reminder points at routing and secret helpers" "yes yes" "$(ctx_has 'tracker_routing.md' 'secret.sh')"
check "reminder keeps the three plain-text exceptions" "yes yes yes" "$(ctx_has 'not in the routing map' 'names a project' 'code span or file path')"
check "reminder tells the model not to mention it" "yes" "$(ctx_has 'Do not mention this reminder')"

rm -f "$hook_out"
echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
