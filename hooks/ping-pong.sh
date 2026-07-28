#!/usr/bin/env bash
# ping-pong.sh — UserPromptSubmit hook: reply "pong" to a bare "ping" message.
set -u

input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
trimmed="$(printf '%s' "$prompt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
lower="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"

[ "$lower" = "ping" ] || exit 0

ctx="The user's message consists solely of \"ping\". Reply with exactly the single word \"pong\" and nothing else."
jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
