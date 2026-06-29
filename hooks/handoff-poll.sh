#!/usr/bin/env bash
# handoff-poll.sh — UserPromptSubmit hook for live handoff auto-pickup.
#
# Each turn, inject any newly-arrived messages on this session's subscribed
# channels into the prompt context. Stays silent when the session watches
# nothing (no subscribe profile) or nothing new has arrived.
#
# The hook payload (JSON) arrives on stdin; we read session_id from it, falling
# back to $CLAUDE_CODE_SESSION_ID. All mailbox work is delegated to the sibling
# handoff.sh — this wrapper only resolves the session and frames the output.
#
# Runs under macOS bash 3.2.

set -u

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"

here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/handoff.sh" poll --session "$sid" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

ctx="Handoff — new messages on your subscribed channels (auto-pickup):

$out"

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
