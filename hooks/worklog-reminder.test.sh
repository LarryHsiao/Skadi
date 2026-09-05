#!/bin/bash
# Offline tests for the worklog reminder hook. The contract: silent unless
# the worklog repo is configured AND the session is rooted under the work
# tree — a personal repo (skadi included) must never see this reminder.
# Run: bash worklog-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/worklog-reminder.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

check_has() { # desc needle haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — [$2] absent from [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

POINTER="$WORK/worklog-repo.md"
WORK_ROOT="$WORK/work"
mkdir -p "$WORK_ROOT/vitallink-ca" "$WORK/skadi"

# ── 1 · no pointer file at all: silent no-op ──
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
check "no pointer file emits nothing" "" "$out"

# ── 2 · an empty pointer file: also a silent no-op ──
: > "$POINTER"
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
check "an empty pointer file emits nothing" "" "$out"

printf '%s\n' "$WORK_ROOT/../worklog" > "$POINTER"

# ── 3 · configured, but the project isn't under the work root: silent ──
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK/skadi" bash "$HOOK")
check "a personal-repo project dir emits nothing" "" "$out"

# ── 4 · configured, and the project IS under the work root: the reminder fires ──
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
shape=$(printf '%s' "$out" | python3 -c "
import json, sys
out = json.load(sys.stdin)['hookSpecificOutput']
print('%s/%s' % (out['hookEventName'], 'yes' if out.get('additionalContext') else 'no'))
")
check "a work-tree project dir emits valid UserPromptSubmit JSON" "UserPromptSubmit/yes" "$shape"
check_has "the reminder names the handoff send target" "/handoff send worklog" "$out"
check_has "the reminder says to fail soft, never block the report" "never let it block the actual completion report" "$out"
check_has "the reminder exempts read-only and nothing-done turns" "Skip entirely for read-only turns" "$out"

# ── 5 · a nested subdirectory of a work project also counts as work ──
mkdir -p "$WORK_ROOT/vitallink-ca/lib/nested"
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca/lib/nested" bash "$HOOK")
check_has "a nested work subdirectory still fires the reminder" "/handoff send worklog" "$out"

# ── 6 · the work root path itself, exactly, still fires ──
# ($WORK_ROOT itself is never a project directory in practice, but the case
# match names it alongside the prefix — worth pinning that it is handled.)
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT" bash "$HOOK")
check_has "the bare work root itself still fires the reminder" "/handoff send worklog" "$out"

# ── 7 · a configured work-root pointer file relocates the boundary ──
# No WORKLOG_WORK_ROOT here — this exercises the pointer-file tier, not the
# env-var override every test above relied on.
ALT_ROOT="$WORK/elsewhere"
mkdir -p "$ALT_ROOT/some-project"
ROOT_POINTER="$WORK/worklog-work-root.md"
printf '%s\n' "$ALT_ROOT" > "$ROOT_POINTER"

out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT_POINTER="$ROOT_POINTER" \
  CLAUDE_PROJECT_DIR="$ALT_ROOT/some-project" bash "$HOOK")
check_has "a relocated work root fires for a project under it" "/handoff send worklog" "$out"

out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT_POINTER="$ROOT_POINTER" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
check "a relocated work root stays silent for the old default location" "" "$out"

# ── 8 · with no override at all, the true default is ~/work ──
# HOME is scoped to this one call so the real machine's ~/work is never
# touched; WORKLOG_WORK_ROOT_POINTER points at a file that doesn't exist,
# so resolution genuinely falls through to the hardcoded $HOME/work default.
FAKE_HOME="$WORK/fakehome"
mkdir -p "$FAKE_HOME/work/some-project"
out=$(HOME="$FAKE_HOME" WORKLOG_REPO_POINTER="$POINTER" \
  WORKLOG_WORK_ROOT_POINTER="$FAKE_HOME/.skadi/worklog-work-root.md" \
  CLAUDE_PROJECT_DIR="$FAKE_HOME/work/some-project" bash "$HOOK")
check_has "with nothing configured, the default is \$HOME/work" "/handoff send worklog" "$out"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
