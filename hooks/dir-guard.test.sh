#!/bin/bash
# Offline tests for the cwd/path guard. Run from anywhere: bash dir-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/dir-guard.sh"
REPO="$(cd "$HERE/.." && pwd)"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Runs the hook from inside the repo (a known-allowed cwd) with the given
# command, and reports whether the result denies.
run_cmd() { # command
  local decision
  decision=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" \
    printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)['hookSpecificOutput']
print('deny' if d.get('permissionDecision') == 'deny' else 'allow')
")
  printf '%s' "$decision"
}

# ── the four dev sinks are allowed, even though they're absolute paths outside the project ──
for sink in /dev/null /dev/stdout /dev/stderr /dev/tty; do
  check "command referencing $sink is allowed" "allow" "$(run_cmd "cat foo 2>$sink")"
done

# ── a genuinely disallowed absolute path is still denied — no regression ──
check "command referencing a real outside path is still denied" "deny" "$(run_cmd "cat /etc/passwd")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
