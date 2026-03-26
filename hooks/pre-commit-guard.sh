#!/bin/bash
# PreToolUse hook: Block git commit if staged files contain secrets
CMD=$(jq -r '.tool_input.command')
if echo "$CMD" | grep -qE '^git commit'; then
  SENSITIVE=$(git diff --cached --name-only 2>/dev/null | grep -iE '\.env|credentials|secret|\.pem|\.key|\.p12|token|\.pfx' || true)
  if [ -n "$SENSITIVE" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Staged files may contain secrets: %s"}}' "$SENSITIVE"
  fi
fi
