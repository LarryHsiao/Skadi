#!/bin/bash
# PreToolUse hook (Bash, Write|Edit|MultiEdit|NotebookEdit):
# Block a session rooted OUTSIDE a protected repo from mutating files inside
# it. Complements dir-guard.sh (home/project bounds) and worktree-guard.sh
# (same-repo cross-worktree) — this hook's one concern: "this repo is
# someone else's business unless you're already standing in it."
#
# Protected repos come from a global flat file, NOT auto-memory — auto-memory
# is scoped per project directory and would be invisible to a session rooted
# elsewhere (the same problem /moria solved for mend_repos.md).
# No CLAUDE_DEV_DIRS escape hatch: protected means protected.

LIST="${PROTECTED_REPOS_FILE:-$HOME/.skadi/protected_repos.md}"
[ -f "$LIST" ] || exit 0

INPUT=$(cat)

normalize() {
  local p="$1"
  p="${p//\\//}"
  p="${p%/}"
  [ -z "$p" ] && p="/"
  if [[ "$p" =~ ^([A-Za-z]):(/.*) ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'
}

RAW_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# Logical pwd (no -P): REPOS entries and the target file path below are never
# symlink-resolved (the target may not even exist yet), so PROJECT_DIR must
# stay in the same raw form or a symlinked tmp/dev dir (e.g. macOS's
# /var -> /private/var) silently breaks the self-edit comparison.
PROJECT_DIR=$(cd "$RAW_PROJECT_DIR" 2>/dev/null && pwd || echo "$RAW_PROJECT_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")

# Raw invoking-shell cwd (not CLAUDE_PROJECT_DIR — a session may have cd'd
# within its own project). Same logical-pwd reasoning as PROJECT_DIR above:
# plain pwd, no -P, to stay in the same unresolved namespace as REPOS.
CWD=$(cd "$PWD" 2>/dev/null && pwd || echo "$PWD")

REPOS=()
CHANNELS=()
while IFS= read -r line; do
  line="${line#- }"
  [ -z "$line" ] && continue
  case "$line" in
    *"→"*) ;;
    *) continue ;;
  esac
  repo="${line%%→*}"
  chan="${line#*→}"
  repo="$(printf '%s' "$repo" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  chan="$(printf '%s' "$chan" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$repo" ] && continue
  REPOS+=("$(normalize "$repo")")
  CHANNELS+=("$chan")
done < "$LIST"

under() {
  case "$2" in
    "$1"|"$1"/*) return 0 ;;
  esac
  return 1
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: %s is protected -- run `/handoff send %s <your change>` instead."}}' "$1" "$1"
  exit 0
}

check_path() {
  local target
  target=$(normalize "$1")
  local i=0
  while [ "$i" -lt "${#REPOS[@]}" ]; do
    local repo="${REPOS[$i]}" chan="${CHANNELS[$i]}"
    if under "$repo" "$target" && ! under "$repo" "$PROJECT_DIR"; then
      deny "$chan"
    fi
    i=$((i+1))
  done
}

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -n "$FILE" ]; then
  check_path "$FILE"
  exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -n "$CMD" ]; then
  TOKENS=$(python3 - "$CMD" 2>/dev/null <<'PYEOF'
import sys, shlex
try:
    for token in shlex.split(sys.argv[1]):
        print(token)
except ValueError:
    pass
PYEOF
)
  while IFS= read -r TOKEN; do
    case "$TOKEN" in
      ~*|--*|-*|"") continue ;;
    esac
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]]; then
      check_path "$TOKEN"
    fi
    # Relative paths with ../ escape the tokenizer's absolute-path check
    # above (e.g. `cat ../protected-repo/CLAUDE.md`) — resolve against the
    # invoking shell's actual cwd and check the result too.
    if [[ "$TOKEN" =~ \.\. ]]; then
      RESOLVED_DIR=$(cd "$CWD" 2>/dev/null && cd "$(dirname "$TOKEN")" 2>/dev/null && pwd)
      if [ -n "$RESOLVED_DIR" ]; then
        check_path "$RESOLVED_DIR/$(basename "$TOKEN")"
      fi
    fi
  done <<< "$TOKENS"
fi

exit 0
