#!/bin/bash
# PostToolUse hook: Run eslint on JS/TS files
FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
if echo "$FILE" | grep -qE '\.(ts|tsx|js|jsx)$'; then
  npx eslint "$FILE" 2>&1 | head -20 || true
fi
