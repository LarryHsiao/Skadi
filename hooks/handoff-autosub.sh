#!/usr/bin/env bash
# handoff-autosub.sh — SessionStart hook: subscribe this session to a handoff
# channel named for the repo it stands in, so sessions sharing a repo can pass
# messages without anyone running /handoff subscribe by hand.
#
# The channel is the basename of the repo root, so every session in the repo —
# including one started in a subdirectory or in a worktree cut from it — meets
# on the same channel. A session standing outside any repo has no repo to name
# and stays silent.
#
# Identity is deliberately left to handoff.sh's default (a short slice of the
# session id) rather than being set to the repo name. The self-filter in
# handoff.sh drops any message whose `from` matches the reader's own, so two
# sessions wearing one name would each take the other's word for its own echo
# and pick up nothing. Distinct ids keep the channel two-way. A session that
# wants a human-readable name overrides it afterward with its own
# `subscribe --from <label>`.
#
# Subscribing is a one-shot write; live pickup is the sibling handoff-poll.sh
# UserPromptSubmit hook, which fires each turn.
#
# The hook payload (JSON) arrives on stdin; we read session_id from it, falling
# back to $CLAUDE_CODE_SESSION_ID. All mailbox work is delegated to the sibling
# handoff.sh — this wrapper only resolves session and channel.
#
# Runs under macOS bash 3.2.

set -u

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
# Without an id every id-less session would share one 'unknown' profile, and the
# self-filter would silence them all. Better to subscribe nobody than everybody.
[ -n "$sid" ] || exit 0

where="${CLAUDE_PROJECT_DIR:-$PWD}"
# In a worktree `--show-toplevel` answers with the worktree's own root, which
# would strand each worktree session on a channel of its own. The common git
# dir points at the origin checkout's .git from every worktree alike, so its
# parent is the repo they were all cut from. Anything else — a bare repo, a
# submodule's .git/modules/… , a git too old for --path-format (pre-2.31) —
# leaves the guard unmatched and falls back to the toplevel as before.
common="$(cd "$where" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "$common" in
  */.git) root="$(dirname "$common")" ;;
  *)      root="$(cd "$where" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)" ;;
esac
[ -n "$root" ] || exit 0

here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/handoff.sh" subscribe "$(basename "$root")" --session "$sid" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

# handoff.sh sanitizes the channel (lowercased, odd chars to '_') and names the
# resolved form in its confirmation. Read it back rather than re-deriving it
# here: a repo named "My Project" subscribes to 'my_project', and a hint naming
# the raw basename would send the reader to the wrong channel.
channel="$(printf '%s' "$out" | sed "s/^subscribed to '\([^']*\)'.*/\1/")"

ctx="Handoff — $out
Messages other sessions leave on this channel arrive on their own each turn; send with /handoff send $channel <message>."

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
