#!/bin/bash
# Offline tests for the worklog reminder hook. The contract: silent ONLY when
# the worklog repo is unconfigured. Once configured, every session logs —
# work and personal alike — and the reminder carries two defaults the
# session may correct: the project directory it came from, and a category.
# Run: bash worklog-reminder.test.sh
#
# The needles below carry literal backticks, matching the code spans in the
# reminder's own text. SC2016 flags each single-quoted one as an expansion
# that will not expand — which is precisely what a fixed-string needle wants.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/worklog-reminder.sh"
pass=0
fail=0
skip=0

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

# ── 3 · a work-tree project: fires, and defaults to the `work` category ──
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
shape=$(printf '%s' "$out" | python3 -c "
import json, sys
out = json.load(sys.stdin)['hookSpecificOutput']
print('%s/%s' % (out['hookEventName'], 'yes' if out.get('additionalContext') else 'no'))
")
check "a work-tree project dir emits valid UserPromptSubmit JSON" "UserPromptSubmit/yes" "$shape"
check_has "a work-tree project defaults to the work category" 'default category is `work`' "$out"
check_has "the reminder names the project directory it came from" 'default project is `vitallink-ca`' "$out"
check_has "the reminder names the handoff send target" "/handoff send worklog-inbox" "$out"
check_has "the reminder names the closed set of categories" '`work`, `personal`' "$out"
check_has "the reminder forbids skipping the entry to dodge the choice" "never skip the entry" "$out"
check_has "the reminder says to fail soft, never block the report" "never let it block the actual completion report" "$out"
check_has "the reminder exempts read-only and nothing-done turns" "Skip entirely for read-only turns" "$out"

# ── 4 · a personal repo outside the work root: ALSO fires, category `personal` ──
# This is the heart of the change — the old contract went silent here, losing
# the entry outright. Now the entry is written and merely labelled differently.
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK/skadi" bash "$HOOK")
check_has "a personal-repo project dir still fires the reminder" "/handoff send worklog-inbox" "$out"
check_has "a personal-repo project defaults to the personal category" 'default category is `personal`' "$out"
check_has "a personal-repo project is named in the reminder" 'default project is `skadi`' "$out"

# ── 5 · a nested subdirectory of a work project still counts as work ──
# The project field is the basename of CLAUDE_PROJECT_DIR, so a session rooted
# below a repo root names that subdirectory — an honest default the session
# corrects, not a claim the hook can resolve on its own.
mkdir -p "$WORK_ROOT/vitallink-ca/lib/nested"
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca/lib/nested" bash "$HOOK")
check_has "a nested work subdirectory still defaults to work" 'default category is `work`' "$out"

# ── 6 · the work root path itself, exactly, still defaults to work ──
# ($WORK_ROOT itself is never a project directory in practice, but the case
# match names it alongside the prefix — worth pinning that it is handled.)
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT" bash "$HOOK")
check_has "the bare work root itself defaults to work" 'default category is `work`' "$out"

# ── 7 · a configured work-root pointer file relocates the default ──
# No WORKLOG_WORK_ROOT here — this exercises the pointer-file tier, not the
# env-var override every test above relied on.
ALT_ROOT="$WORK/elsewhere"
mkdir -p "$ALT_ROOT/some-project"
ROOT_POINTER="$WORK/worklog-work-root.md"
printf '%s\n' "$ALT_ROOT" > "$ROOT_POINTER"

out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT_POINTER="$ROOT_POINTER" \
  CLAUDE_PROJECT_DIR="$ALT_ROOT/some-project" bash "$HOOK")
check_has "a relocated work root defaults to work for a project under it" 'default category is `work`' "$out"

# The old location is no longer work — but it still logs, now as personal.
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT_POINTER="$ROOT_POINTER" \
  CLAUDE_PROJECT_DIR="$WORK_ROOT/vitallink-ca" bash "$HOOK")
check_has "the old location still logs once the root moves" "/handoff send worklog-inbox" "$out"
check_has "the old location defaults to personal once the root moves" 'default category is `personal`' "$out"

# ── 8 · with no override at all, the true default root is ~/work ──
# HOME is scoped to this one call so the real machine's ~/work is never
# touched; WORKLOG_WORK_ROOT_POINTER points at a file that doesn't exist,
# so resolution genuinely falls through to the hardcoded $HOME/work default.
FAKE_HOME="$WORK/fakehome"
mkdir -p "$FAKE_HOME/work/some-project"
out=$(HOME="$FAKE_HOME" WORKLOG_REPO_POINTER="$POINTER" \
  WORKLOG_WORK_ROOT_POINTER="$FAKE_HOME/.skadi/worklog-work-root.md" \
  CLAUDE_PROJECT_DIR="$FAKE_HOME/work/some-project" bash "$HOOK")
check_has "with nothing configured, \$HOME/work still defaults to work" 'default category is `work`' "$out"

# ── 9 · a project name bearing a double quote keeps the JSON well-formed ──
# The project name is interpolated into a JSON string; an unescaped quote
# would emit malformed JSON, which the harness discards in silence.
ODD="$WORK_ROOT/say-\"hi\""
mkdir -p "$ODD"
out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
  CLAUDE_PROJECT_DIR="$ODD" bash "$HOOK")
shape=$(printf '%s' "$out" | python3 -c "
import json, sys
try:
    json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
    print('valid')
except Exception:
    print('malformed')
")
check "a quote in the project name still emits valid JSON" "valid" "$shape"

# ── 10 · a project name bearing a backslash is doubled, not passed raw ──
# CLAUDE_PROJECT_DIR need not exist: RESOLVED falls back to the raw path when
# `cd` fails, so this needs nothing of the filesystem. Whether a backslash can
# reach the project name at all is the platform's call, though — MSYS/Windows
# basename splits on it, POSIX basename does not — so ask this platform rather
# than assume, and say plainly when the branch is out of reach here instead of
# skipping in silence.
RAW='/nowhere/back\slash'
case "$(basename "$RAW")" in
  *\\*)
    out=$(WORKLOG_REPO_POINTER="$POINTER" WORKLOG_WORK_ROOT="$WORK_ROOT" \
      CLAUDE_PROJECT_DIR="$RAW" bash "$HOOK")
    check_has "a backslash in the project name is emitted doubled" 'back\\slash' "$out"
    ;;
  *)
    echo "  n/a  · a backslash cannot reach the project name — this platform's basename splits on it"
    skip=$((skip + 1))
    ;;
esac

echo ""
echo "── $pass passed, $fail failed, $skip not applicable here ──"
[[ "$fail" -eq 0 ]]
