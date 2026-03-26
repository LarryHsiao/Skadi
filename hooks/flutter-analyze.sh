#!/bin/bash
# PostToolUse hook: Run flutter analyze on .dart files
FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
if echo "$FILE" | grep -qE '\.dart$'; then
  fvm flutter analyze "$FILE" 2>&1 | head -20 || true
fi
