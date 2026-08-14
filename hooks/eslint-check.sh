#!/bin/bash
# PostToolUse hook: Run eslint on JS/TS files
[ -f package.json ] || exit 0

FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
if echo "$FILE" | grep -qE '\.(ts|tsx|js|jsx)$'; then
  if ! out=$(npx eslint "$FILE" 2>&1); then
    printf '%s\n' "$out" | head -20
    exit 1
  fi
fi
