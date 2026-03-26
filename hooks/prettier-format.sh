#!/bin/bash
# PostToolUse hook: Auto-format web files with prettier
FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
if echo "$FILE" | grep -qE '\.(ts|tsx|js|jsx|css|json|html)$'; then
  npx prettier --write "$FILE" 2>/dev/null || true
fi
