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
  # Preserve root "/" (stripping trailing slash from "/" yields "")
  [ -z "$p" ] && p="/"
  # Convert C:/... to /c/...
  if [[ "$p" =~ ^([A-Za-z]):(/.*) ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Convert /mnt/c/... to /c/... (WSL/Git Bash on Windows)
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Lowercase everything for case-insensitive comparison on Windows.
  # Use tr, not ${p,,} — the latter is bash 4+ and macOS ships bash 3.2.
  printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'
}

CWD=$(normalize "$CWD")
HOME_DIR=$(normalize "$HOME_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")

# User dev directories — colon-separated, set via CLAUDE_DEV_DIRS env var
# e.g. export CLAUDE_DEV_DIRS="~/phantom:~/work"
IFS=: read -ra _RAW_DEV_DIRS <<< "${CLAUDE_DEV_DIRS:-}"
DEV_DIRS=()
for _d in "${_RAW_DEV_DIRS[@]}"; do
  _d="${_d/#\~/$HOME}"  # expand leading ~
  DEV_DIRS+=("$(normalize "$_d")")
done

# Returns 0 if path is under project dir, .claude dir, /tmp, or any dev dir
in_allowed_dir() {
  local p="$1"
  case "$p" in
    "$PROJECT_DIR"|"$PROJECT_DIR"/*) return 0 ;;
    "$HOME_DIR"/.claude|"$HOME_DIR"/.claude/*) return 0 ;;
    "$HOME_DIR"/.claude-personal|"$HOME_DIR"/.claude-personal/*) return 0 ;;
    "$HOME_DIR"/.claude-work|"$HOME_DIR"/.claude-work/*) return 0 ;;
    /tmp|/tmp/*) return 0 ;;
    /private/tmp|/private/tmp/*) return 0 ;;
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty) return 0 ;;
  esac
  for _d in "${DEV_DIRS[@]}"; do
    case "$p" in
      "$_d"|"$_d"/*) return 0 ;;
    esac
  done
  return 1
}

# Check if at disk root (/, /c, /d, etc.)
if echo "$CWD" | grep -qE '^/$|^/[a-z]$'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: running at disk root (%s) is not allowed"}}' "$CWD"
  exit 0
fi

# Check if outside user home. On the Claude Code remote container ($HOME
# may be /root while the project lives under /home/user/...), the project
# dir and dev dirs are admitted even though they fall outside HOME — the
# downstream in_allowed_dir check still enforces project / .claude / /tmp /
# dev. On local machines the strict home check stays in place.
case "$CWD" in
  "$HOME_DIR"|"$HOME_DIR"/*)
    ;; # ok, under home
  *)
    if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && in_allowed_dir "$CWD"; then
      :  # ok — remote container, cwd is project/dev/.claude/tmp
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside home directory (%s)"}}' "$CWD" "$HOME_DIR"
      exit 0
    fi
    ;;
esac

# Check if outside project dir and dev dirs
if ! in_allowed_dir "$CWD"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside project and dev directories"}}' "$CWD"
  exit 0
fi

# Check command arguments for absolute paths outside the project.
# Uses Python's shlex for quote-aware tokenization so paths inside
# quoted strings (e.g. commit messages, echo args) are not flagged.
CMD=$(echo "$INPUT" | jq -r '.tool_input.command' 2>/dev/null)
if [ -n "$CMD" ]; then
  TOKENS=$(python3 - "$CMD" 2>/dev/null <<'PYEOF'
import re, sys, shlex
try:
    for token in shlex.split(sys.argv[1]):
        # shlex only understands words and quoting, not shell control
        # operators — a trailing ";", "&&", "||", "|", ")", ">" glued to a
        # path with no space (e.g. "for x in a; do") rides along as part of
        # the token instead of being split off. Strip it so the path check
        # compares the real path, not the path plus punctuation.
        print(re.sub(r'[;&|()<>]+$', '', token))
except ValueError:
    pass  # unparseable (e.g. bare heredoc) — skip path checks
PYEOF
)
  while IFS= read -r TOKEN; do
    case "$TOKEN" in
      ~*|--*|-*|"") continue ;;
    esac
    # Check for absolute paths (/c/..., /usr/..., C:\..., C:/... — the
    # forward-slash form is what Git Bash users actually type on Windows).
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]] || [[ "$TOKEN" =~ ^[A-Za-z]:/ ]]; then
      NORM=$(normalize "$TOKEN")
      if ! in_allowed_dir "$NORM"; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: command references path (%s) outside project and dev directories"}}' "$NORM"
        exit 0
      fi
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
  done <<< "$TOKENS"
fi

# All checks passed — log cwd as informational message
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","message":"cwd: %s"}}' "$CWD"
