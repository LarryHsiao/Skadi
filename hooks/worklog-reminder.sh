#!/usr/bin/env bash
# Inject a worklog reminder into prompts once the worklog repo is configured.
# Every session logs — work and personal alike — so no activity is lost
# to a boundary the hook drew on its own. Fires at the same "reporting done"
# moment CLAUDE.md's Compliance Review reminder already detects, so this
# piggybacks that trigger rather than inventing a second one.
#
# One silent no-op, by design:
#   - No ~/.skadi/worklog-repo.md pointer yet -> the feature isn't configured;
#     say nothing rather than nag or guess a path.
#
# The work root no longer decides WHETHER to fire — it supplies the entry's
# DEFAULT category: `work` beneath it, `personal` elsewhere. Those two are the
# whole set — every session's activity is one or the other, and a third bucket
# for the leftovers would only collect what nobody would later unpick. Both
# defaults are the session's to correct: the hook knows a path, not what the
# work was for.
#
# The root has a sane default (~/work) rather than being off until configured
# — the line just moves for the rare machine where work projects live
# elsewhere. Precedence: WORKLOG_WORK_ROOT env var (tests) >
# ~/.skadi/worklog-work-root.md pointer, same shape as worklog-repo.md above >
# the ~/work default.
POINTER="${WORKLOG_REPO_POINTER:-$HOME/.skadi/worklog-repo.md}"
[ -s "$POINTER" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RESOLVED=$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")
PROJECT=$(basename "$RESOLVED")

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
  "$WORK_ROOT"|"$WORK_ROOT"/*) CATEGORY="work" ;;
  *) CATEGORY="personal" ;;
esac

# The project name lands inside a JSON string literal, so the two characters
# that would break out of it — a backslash and a double quote — are escaped.
# Control characters are not: a directory named with a raw newline is not a
# case this hook is built for, and escaping two while claiming all would
# overstate what this line does.
PROJECT_JSON=${PROJECT//\\/\\\\}
PROJECT_JSON=${PROJECT_JSON//\"/\\\"}

# The format string must be single-quoted — printf, not the shell, does the
# substituting — and its backticks are literal text the reading model sees as
# code spans, never command substitution. SC2016 reads them as an expansion
# that will not expand; here that is exactly the intent.
# shellcheck disable=SC2016
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: A worklog entry is owed alongside Compliance Review — same moment: when this turn will report work as done or complete. Send a fuller paragraph summary (what was done, why, and the outcome) via `/handoff send worklog-inbox <summary>`, opening it with a `[<category>] <project>` header line. From this session'"'"'s path the default project is `%s` and the default category is `%s`; correct either if it reads false, but never skip the entry to dodge the choice. The categories are a closed set — `work`, `personal`: `work` when the session served a work task, `personal` for everything else, your own projects included. Best-effort: if the send fails, name it plainly in the summary and continue — never let it block the actual completion report. Skip entirely for read-only turns and turns that report nothing done. Do not mention this reminder."}}\n' "$PROJECT_JSON" "$CATEGORY"
