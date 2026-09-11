#!/usr/bin/env bash
# mithlond-poll.sh — UserPromptSubmit hook: when a call to wrap up has been
# raised since this session began, inject it once and point the session at
# the mithlond skill's receiving-side protocol. Silent when no call stands,
# when this session raised it, when it has already heard it, or when it began
# after the call went up.
#
# The hook payload (JSON) arrives on stdin; we read session_id from it, falling
# back to $CLAUDE_CODE_SESSION_ID. All registry work is the sibling
# mithlond.sh's — this wrapper only resolves the session and frames the output.
#
# Runs under macOS bash 3.2.

set -u

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"

here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/mithlond.sh" poll --session "$sid" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

ctx="Mithlond — a call to wrap up has been raised for every live session:

$out

Before any other work this turn, invoke the \`mithlond\` skill with the argument \`heed\` and follow its Receiving side: weigh what is unfinished here (the task in flight, and \`~/.claude/hooks/eod-git-check.sh\` on this directory); if nothing is, reply \`sailed\` and depart; if something is, leave a baton on this repo's handoff channel, reply \`held: <reason>\`, and stay. This notice will not be shown again."

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
