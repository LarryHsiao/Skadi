#!/bin/bash
# PostToolUse hook: Warn when destructive commands are executed
CMD=$(jq -r '.tool_input.command')
if echo "$CMD" | grep -qE '^\s*(rm |rm -|mv |chmod |chown |sed -i|find .* -delete)'; then
  printf '{"systemMessage":"Destructive command was executed — verify no unintended changes occurred.","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"A potentially destructive command ran. Verify the result."}}'
fi
