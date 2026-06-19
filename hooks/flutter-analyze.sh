#!/bin/bash
# PostToolUse hook: format (write), analyze, and test on .dart file changes
FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
if echo "$FILE" | grep -qE '\.dart$'; then
  fvm dart format "$FILE" 2>&1 | head -5 || true
  fvm flutter analyze "$FILE" 2>&1 | head -20 || true
  fvm flutter test 2>&1 | tail -20 || true
fi
