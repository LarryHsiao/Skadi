#!/bin/bash
# PreToolUse hook: Log cwd and block Bash commands outside the project directory

# Capture stdin immediately (hook input JSON)
INPUT=$(cat)

# Canonical paths (resolve symlinks, normalize slashes)
CWD=$(cd "$PWD" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$PWD")
HOME_DIR=$(cd "$HOME" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$HOME")
PROJECT_DIR=$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")

# Normalize: lowercase everything, forward slashes, strip trailing slash
normalize() {
  local p="$1"
  # Convert backslashes to forward slashes, strip trailing slash
  p="${p//\\//}"
  p="${p%/}"
  # Convert C:/... to /c/...
  if [[ "$p" =~ ^([A-Za-z]):(/.*) ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Convert /mnt/c/... to /c/... (WSL/Git Bash on Windows)
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Lowercase everything for case-insensitive comparison on Windows
  echo "${p,,}"
}

CWD=$(normalize "$CWD")
HOME_DIR=$(normalize "$HOME_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")

# Check if at disk root (/, /c, /d, etc.)
if echo "$CWD" | grep -qE '^(/[a-z])?$'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: running at disk root (%s) is not allowed"}}' "$CWD"
  exit 0
fi

# Check if outside user home
case "$CWD" in
  "$HOME_DIR"|"$HOME_DIR"/*)
    ;; # ok, under home
  *)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside home directory (%s)"}}' "$CWD" "$HOME_DIR"
    exit 0
    ;;
esac

# Check if outside project directory
case "$CWD" in
  "$PROJECT_DIR"|"$PROJECT_DIR"/*)
    ;; # ok, inside project
  *)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside project directory (%s)"}}' "$CWD" "$PROJECT_DIR"
    exit 0
    ;;
esac

# Check command arguments for absolute paths outside the project
CMD=$(echo "$INPUT" | jq -r '.tool_input.command' 2>/dev/null)
if [ -n "$CMD" ]; then
  # Split command into tokens and check each for absolute paths
  # Skip tokens that are part of ~/ paths or flags
  for TOKEN in $CMD; do
    # Skip ~ paths, flags, and non-path tokens
    case "$TOKEN" in
      ~*|--*|-*) continue ;;
    esac
    # Check for absolute paths (/c/..., /usr/..., C:\...)
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]]; then
      NORM=$(normalize "$TOKEN")
      case "$NORM" in
        "$PROJECT_DIR"|"$PROJECT_DIR"/*)
          ;; # ok, inside project
        "$HOME_DIR"/.claude|"$HOME_DIR"/.claude/*)
          ;; # ok, claude config dir
        *)
          printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: command references path (%s) outside project directory (%s)"}}' "$NORM" "$PROJECT_DIR"
          exit 0
          ;;
      esac
    fi
    # Check for relative paths with ../ that escape the project
    if [[ "$TOKEN" =~ \.\. ]]; then
      RESOLVED=$(cd "$CWD" 2>/dev/null && cd "$(dirname "$TOKEN")" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null)
      if [ -n "$RESOLVED" ]; then
        RESOLVED=$(normalize "$RESOLVED/$(basename "$TOKEN")")
        case "$RESOLVED" in
          "$PROJECT_DIR"|"$PROJECT_DIR"/*)
            ;; # ok, resolves inside project
          *)
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: relative path (%s) resolves to (%s) outside project directory (%s)"}}' "$TOKEN" "$RESOLVED" "$PROJECT_DIR"
            exit 0
            ;;
        esac
      fi
    fi
  done
fi

# All checks passed — log cwd as informational message
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","message":"cwd: %s"}}' "$CWD"
