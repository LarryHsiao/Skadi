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

# ── an allowed path glued to a trailing shell operator (no space) is still allowed —
# shlex.split doesn't treat these as separators, so a naive check would see
# ".claude-work;" and miss the exact/glob match against ".claude-work" ──
for op in ";" "&&" "||" "|" ")" ">"; do
  check "allowed path glued to trailing '$op' is still allowed" "allow" "$(run_cmd "echo $HOME/.claude-work$op echo done")"
done

# ── a disallowed path glued to a trailing operator is still denied, not smuggled through ──
check "disallowed path glued to trailing ';' is still denied" "deny" "$(run_cmd "cat /etc/passwd; echo done")"

# ── a forward-slash Windows path (C:/..., what Git Bash users actually type) is
# caught by the same check that already catches the backslash form (C:\...) ──
check "forward-slash Windows path is denied like its backslash form" "deny" "$(run_cmd 'cat C:/Windows/System32/config')"

# ── a command's own executable path outside the project is exempt — locating
# a binary isn't a sandbox escape the way an out-of-project file argument is ──
check "command's own absolute path is allowed" "allow" "$(run_cmd "/opt/homebrew/bin/git status")"
check "command's own absolute path is allowed in every chain slot" "allow" "$(run_cmd "echo hi && /opt/homebrew/bin/git status")"

# ── the same path used as an *argument*, not the command being run, is still
# denied — the exemption covers the executable slot only ──
check "outside path used as an argument is still denied" "deny" "$(run_cmd "cat /opt/homebrew/bin/git")"

# Runs the hook from inside the repo (a known-allowed cwd) as a Write/Edit-style
# call — tool_input carries file_path instead of command — and reports whether
# the result denies. An optional third arg sets CLAUDE_DEV_DIRS for the call.
run_write() { # file_path [dev_dirs]
  local decision
  decision=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" CLAUDE_DEV_DIRS="${2:-}" \
    printf '{"tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_DEV_DIRS="${2:-}" bash "$HOOK" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)['hookSpecificOutput']
print('deny' if d.get('permissionDecision') == 'deny' else 'allow')
")
  printf '%s' "$decision"
}

# ── Write/Edit/NotebookEdit tools carry file_path, not command — the guard
# must gate that field too, not just Bash's command string ──
check "Write file_path inside project is allowed" "allow" "$(run_write "$REPO/hooks/dir-guard.sh")"
check "Write file_path outside project is denied" "deny" "$(run_write "/etc/passwd")"
check "Write file_path under .claude-personal is allowed" "allow" "$(run_write "$HOME/.claude-personal/hooks/foo.sh")"

# ── the CLAUDE_DEV_DIRS whitelist governs file_path exactly as it governs
# Bash command args — same in_allowed_dir check, same allowance ──
OUTSIDE_PATH="$HOME/some-other-project/file.txt"
check "Write file_path outside project with no dev-dir whitelist is denied" "deny" "$(run_write "$OUTSIDE_PATH")"
check "Write file_path inside CLAUDE_DEV_DIRS whitelist is allowed" "allow" "$(run_write "$OUTSIDE_PATH" "$HOME/some-other-project")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
