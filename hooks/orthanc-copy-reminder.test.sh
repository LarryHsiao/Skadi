#!/bin/bash
# Offline test for the Orthanc copy-marker reminder hook. The contract: valid
# UserPromptSubmit JSON whose reminder names the helper, the marker, the widened
# block kinds, and tells the model not to mention it.
# Run: bash orthanc-copy-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/orthanc-copy-reminder.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

hook_out="$(mktemp)"
bash "$HOOK" > "$hook_out"

expected_shape="UserPromptSubmit/yes"
actual_shape=$(python3 - "$hook_out" <<'PY'
import json, sys
out = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]
print("%s/%s" % (out["hookEventName"], "yes" if out.get("additionalContext") else "no"))
PY
)
check "hook emits valid UserPromptSubmit JSON with context" "$expected_shape" "$actual_shape"

expected_tokens="helper:yes marker:yes"
actual_tokens=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print("helper:%s marker:%s" % ("yes" if "orthanc-copy.py" in ctx else "no",
                               "yes" if "⧉ copy:" in ctx else "no"))
PY
)
check "reminder names the helper and the marker" "$expected_tokens" "$actual_tokens"

expected_kinds="note:yes body:yes draft:yes"
actual_kinds=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print("note:%s body:%s draft:%s" % ("yes" if "release note" in ctx else "no",
                                    "yes" if "PR or ticket body" in ctx else "no",
                                    "yes" if "message draft" in ctx else "no"))
PY
)
check "reminder covers release notes, PR/ticket bodies, message drafts" "$expected_kinds" "$actual_kinds"

expected_quiet="yes"
actual_quiet=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print("yes" if "not mention this reminder" in ctx else "no")
PY
)
check "reminder tells the model not to mention it" "$expected_quiet" "$actual_quiet"

rm -f "$hook_out"
echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
