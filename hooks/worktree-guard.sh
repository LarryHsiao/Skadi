#!/bin/bash
# PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit):
# Block edits to a file that belongs to the SAME repository as the session
# but lives in a DIFFERENT worktree / the main checkout.
#
# Why: a session rooted in a git worktree (e.g. .../.claude/worktrees/FOO)
# must not edit the main checkout or a sibling worktree of the same repo —
# the edit lands on the wrong branch and never reaches the tree being built.
# This complements dir-guard.sh (which only guards Bash and admits the whole
# dev dir). Unrelated repos (a different project, ~/Minerva, /tmp) are NOT
# affected — only same-repo, cross-worktree edits are blocked.

INPUT=$(cat)

# Target path: Edit/Write/MultiEdit use file_path; NotebookEdit uses notebook_path.
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Nearest existing directory at or above the target (the file itself may be new).
FILE_DIR=$(dirname "$FILE")
while [ ! -d "$FILE_DIR" ] && [ "$FILE_DIR" != "/" ] && [ "$FILE_DIR" != "." ]; do
  FILE_DIR=$(dirname "$FILE_DIR")
done
[ -d "$FILE_DIR" ] || exit 0

# Real path to a repo's toplevel (working-tree root) for the dir holding $1.
top_dir() {
  local t
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  ( cd "$t" 2>/dev/null && pwd -P )
}

# Real path to a repo's shared .git common dir for the dir holding $1.
# All worktrees of one repo share the same common dir; each has its own toplevel.
common_dir() {
  local c
  c=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$c" in
    /*) : ;;            # absolute already
    *) c="$1/$c" ;;     # relative — resolve against the queried dir
  esac
  ( cd "$c" 2>/dev/null && pwd -P )
}

SESS_TOP=$(top_dir "$PWD")
SESS_COMMON=$(common_dir "$PWD")
# Session not inside a git repo → nothing to protect.
[ -z "$SESS_TOP" ] && exit 0

FILE_TOP=$(top_dir "$FILE_DIR")
FILE_COMMON=$(common_dir "$FILE_DIR")
# Target not in a git repo → unrelated, allow.
[ -z "$FILE_TOP" ] && exit 0

# Same repository (shared .git) but a different working tree → wrong checkout.
if [ -n "$SESS_COMMON" ] && [ "$FILE_COMMON" = "$SESS_COMMON" ] && [ "$FILE_TOP" != "$SESS_TOP" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: %s is the same repo but a DIFFERENT worktree/checkout. This session is rooted at %s — edit the copy inside that worktree, not this one."}}' "$FILE" "$SESS_TOP"
  exit 0
fi

exit 0
