#!/usr/bin/env bash
# mithlond-presence.sh — SessionStart / SessionEnd hook: keep this session on
# the Grey Havens' roster of live sessions while it runs, and strike it off
# when it ends. One script serves both events; the payload's hook_event_name
# says which.
#
# The hook payload (JSON) arrives on stdin; we read session_id from it, falling
# back to $CLAUDE_CODE_SESSION_ID. Registration records the session's claude
# pid — mithlond.sh finds it by walking up from this hook to the nearest
# ancestor whose command is claude — so the roster can prune a session whose
# process died without this hook's SessionEnd ever firing.
#
# Silent on both events: presence is bookkeeping, not context.
#
# Runs under macOS bash 3.2.

set -u

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
# An id-less session cannot be told apart from the next one; register nobody.
[ -n "$sid" ] || exit 0

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
here="$(cd "$(dirname "$0")" && pwd)"

case "$event" in
  SessionEnd)
    "$here/mithlond.sh" unregister --session "$sid" 2>/dev/null || true ;;
  *)
    "$here/mithlond.sh" register --session "$sid" --cwd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true ;;
esac
exit 0
