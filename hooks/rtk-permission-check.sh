#!/usr/bin/env bash
# Runs after rtk-rewrite.sh. If the command was rewritten to "rtk <original>",
# checks whether <original> was in the Claude Code allow list. If not, overrides
# the auto-allow with "ask" so the user gets prompted.

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

# Only concern ourselves with rtk-rewritten commands
[[ "$CMD" == "rtk "* ]] || exit 0

ORIGINAL="${CMD#rtk }"

SETTINGS_FILE="$HOME/.claude/settings.json"
[ -f "$SETTINGS_FILE" ] || exit 0

permitted=false
while IFS= read -r prefix; do
  [ -z "$prefix" ] && continue
  if [[ "$ORIGINAL" == "$prefix" || "$ORIGINAL" == "$prefix "* ]]; then
    permitted=true
    break
  fi
done < <(jq -r '.permissions.allow[]? | select(test("^Bash\\(.+:\\*\\)$")) | ltrimstr("Bash(") | rtrimstr(":*)")' "$SETTINGS_FILE" 2>/dev/null)

if [ "$permitted" = "false" ]; then
  jq -n --arg cmd "$ORIGINAL" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": ("rtk: original command not in allow list: " + $cmd)
    }
  }'
fi
