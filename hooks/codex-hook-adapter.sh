#!/usr/bin/env bash
# Translate Codex hook payloads into the Claude-compatible shape consumed by
# Skadi's existing hooks. apply_patch can touch several files, so file-oriented
# hooks receive one synthetic Write payload per patch path.

set -u

target="${1:-}"
[ -n "$target" ] || { echo "codex-hook-adapter: missing target hook" >&2; exit 1; }
[ -f "$target" ] || { echo "codex-hook-adapter: hook not found: $target" >&2; exit 1; }

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$cwd}"
export CODEX_PROJECT_DIR="${CODEX_PROJECT_DIR:-$cwd}"
export CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)}"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
if [ "$tool_name" != "apply_patch" ]; then
  printf '%s' "$input" | "$target"
  exit $?
fi

patch="$(printf '%s' "$input" | jq -r \
  '.tool_input.patch // .tool_input.command // .tool_input.input // empty' \
  2>/dev/null || true)"
paths="$(printf '%s\n' "$patch" | sed -n \
  -e 's/^\*\*\* Add File: //p' \
  -e 's/^\*\*\* Update File: //p' \
  -e 's/^\*\*\* Delete File: //p' \
  -e 's/^\*\*\* Move to: //p')"
[ -n "$paths" ] || exit 0

outputs=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    /* | [A-Za-z]:[\\/]*) absolute="$path" ;;
    *) absolute="$cwd/$path" ;;
  esac
  absolute="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$absolute")"
  payload="$(printf '%s' "$input" | jq --arg path "$absolute" \
    '.tool_name = "Write" | .tool_input = {file_path: $path}')" || exit 1
  output="$(printf '%s' "$payload" | "$target")"
  status=$?
  if [ -n "$output" ]; then
    outputs="${outputs}${outputs:+$'\n'}${output}"
  fi
  [ "$status" -eq 0 ] || exit "$status"
  if printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny" or .decision == "block"' >/dev/null 2>&1; then
    printf '%s\n' "$output"
    exit 0
  fi
done <<< "$paths"

[ -n "$outputs" ] || exit 0
if printf '%s\n' "$outputs" | jq -s -e 'all(.[]; type == "object")' >/dev/null 2>&1; then
  printf '%s\n' "$outputs" | jq -s '
    .[0] as $first
    | ([.[].hookSpecificOutput.additionalContext? // empty] | join("\n")) as $context
    | ([.[].systemMessage? // empty] | join("\n")) as $messages
    | $first
    | if $context != "" then
        .hookSpecificOutput = (.hookSpecificOutput // {})
        | .hookSpecificOutput.additionalContext = $context
      else . end
    | if $messages != "" then .systemMessage = $messages else . end
  '
else
  printf '%s\n' "$outputs" | tail -n 1
fi
