#!/usr/bin/env bash
# Inject a worklog reminder into prompts for sessions rooted under ~/work/ —
# work-task activity only, never a personal repo (skadi included). Fires at
# the same "reporting done" moment CLAUDE.md's Compliance Review reminder
# already detects, so this piggybacks that trigger rather than inventing a
# second one.
#
# Two silent no-ops, by design:
#   - No ~/.skadi/worklog-repo.md pointer yet -> the feature isn't configured;
#     say nothing rather than nag or guess a path.
#   - CLAUDE_PROJECT_DIR isn't under the work root -> this is a personal-repo
#     session; the worklog records work tasks only.
#
# Unlike the repo-location pointer above, the work root has a sane default
# (~/work) rather than being off until configured — the boundary just moves
# for the rare machine where work projects live somewhere else. Precedence:
# WORKLOG_WORK_ROOT env var (tests) > ~/.skadi/worklog-work-root.md pointer,
# same shape as worklog-repo.md above > the ~/work default.
POINTER="${WORKLOG_REPO_POINTER:-$HOME/.skadi/worklog-repo.md}"
[ -s "$POINTER" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RESOLVED=$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")

if [ -n "${WORKLOG_WORK_ROOT:-}" ]; then
  WORK_ROOT="$WORKLOG_WORK_ROOT"
else
  ROOT_POINTER="${WORKLOG_WORK_ROOT_POINTER:-$HOME/.skadi/worklog-work-root.md}"
  if [ -s "$ROOT_POINTER" ]; then
    WORK_ROOT="$(head -n 1 "$ROOT_POINTER")"
  else
    WORK_ROOT="$HOME/work"
  fi
fi

case "$RESOLVED" in
  "$WORK_ROOT"|"$WORK_ROOT"/*) ;;
  *) exit 0 ;;
esac

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: This session is rooted under the work tree, so a worklog entry is owed alongside Compliance Review — same moment: when this turn will report work as done or complete. Send a fuller paragraph summary (what was done, why, and the outcome) via `/handoff send worklog <summary>` before the final report. Best-effort: if the send fails, name it plainly in the summary and continue — never let it block the actual completion report. Skip entirely for read-only turns and turns that report nothing done. Do not mention this reminder."}}
EOF
