#!/bin/bash
# Offline tests for the pipefail guard. The contract: a test or lint run piped
# without `set -o pipefail` is denied with a reason naming the prefix; every
# other command passes silently; and any trouble inside the hook lets the call
# through rather than blocking work.
# Run: bash pipefail-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/pipefail-guard.py"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# decision <hook> <command> — "deny:<names the prefix yes|no>" or "allow"
decision() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2" \
    | python3 "$1" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow"); sys.exit()
out = json.loads(raw)["hookSpecificOutput"]
names = "yes" if "set -o pipefail" in out.get("permissionDecisionReason", "") else "no"
print("%s:%s" % (out["permissionDecision"], names))'
}

# ── 1 · a piped test run without pipefail is denied, and the reason names the fix ──
expected_deny="deny:yes"
actual_deny=$(decision "$HOOK" "flutter test 2>&1 | tail -5")
check "piped test run without pipefail is denied with the prefix named" "$expected_deny" "$actual_deny"

# ── 2 · the same run under pipefail passes ──
expected_pf="allow"
actual_pf=$(decision "$HOOK" "set -o pipefail; flutter test 2>&1 | tail -5")
check "piped test run under set -o pipefail passes" "$expected_pf" "$actual_pf"

# ── 3 · an unpiped run already reports its own status, and passes ──
expected_plain="allow"
actual_plain=$(decision "$HOOK" "fvm flutter test test/foo_test.dart")
check "unpiped test run passes" "$expected_plain" "$actual_plain"

# ── 4 · a command that only names a test file is not a run, and passes ──
expected_mention="allow"
actual_mention=$(decision "$HOOK" "grep -n narya hooks/board-refresh-wiring.test.sh | head -5")
check "grep naming a test file passes" "$expected_mention" "$actual_mention"

# ── 5 · a piped lint run without pipefail is denied too ──
expected_lint="deny:yes"
actual_lint=$(decision "$HOOK" "flutter analyze 2>&1 | tail -3")
check "piped lint run without pipefail is denied" "$expected_lint" "$actual_lint"

# ── 5b · `|| echo` masks the status as surely as a pipe, and is denied ──
expected_or="deny:yes"
actual_or=$(decision "$HOOK" "npm test || echo failed")
check "test run followed by || echo is denied" "$expected_or" "$actual_or"

# ── 5c · knowing exception, pinned: a quoted | reads as a pipe and is denied ──
expected_quoted="deny:yes"
actual_quoted=$(decision "$HOOK" 'pytest -k "parse|write"')
check "quoted | is denied (accepted: inherited from /este's reading)" "$expected_quoted" "$actual_quoted"

# ── 5d · a deny exits 0 — the decision rides in the JSON, not the status ──
expected_status="0"
actual_status=$(python3 -c 'import json; print(json.dumps({"tool_input":{"command":"pytest | tail -3"}}))' \
  | python3 "$HOOK" >/dev/null; printf '%s' "$?")
check "deny path exits 0" "$expected_status" "$actual_status"

# ── 5e · a payload carrying no command passes ──
expected_nocmd="allow"
actual_nocmd=$(printf '{"tool_name":"Bash","tool_input":{}}' | python3 "$HOOK" 2>/dev/null)
actual_nocmd=${actual_nocmd:-allow}
check "payload without a command passes" "$expected_nocmd" "$actual_nocmd"

# ── 6 · a malformed payload lets the call through, exit 0 ──
expected_bad="allow/0"
actual_bad=$(printf 'not json' | python3 "$HOOK" 2>/dev/null; printf 'allow/%s' "$?")
check "malformed stdin fails open" "$expected_bad" "$actual_bad"

# ── 6b · failing open says so on stderr, so a broken guard is not mistaken for a pass ──
expected_note="yes"
actual_note=$(printf 'not json' | python3 "$HOOK" 2>&1 >/dev/null | grep -q 'pipefail-guard: skipped' && echo yes || echo no)
check "fail-open leaves a note on stderr" "$expected_note" "$actual_note"

# ── 7 · with no pulse-scan beside it, the hook fails open instead of blocking ──
lonely="$(mktemp -d)"
trap 'rm -rf "$lonely"' EXIT
cp "$HOOK" "$lonely/pipefail-guard.py"
expected_lonely="allow"
actual_lonely=$(decision "$lonely/pipefail-guard.py" "flutter test | tail -5" 2>/dev/null)
check "missing pulse-scan fails open" "$expected_lonely" "$actual_lonely"

# ── 8 · with pulse-scan present but the rubric missing, it fails open too ──
cp "$HERE/pulse-scan.py" "$lonely/pulse-scan.py"
expected_norubric="allow"
actual_norubric=$(decision "$lonely/pipefail-guard.py" "flutter test | tail -5" 2>/dev/null)
check "missing rubric fails open" "$expected_norubric" "$actual_norubric"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
