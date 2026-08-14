#!/bin/bash
# PostToolUse hook: format Dart files on write.
#
# Analysis and tests are deliberately NOT run here. A full `flutter test`
# measured 13m41s on vitallink-ca, billed after every single edit; both it
# and `flutter analyze` belong to the Implementation Loop's own explicit
# verification step, where the check is named and its evidence is read.
FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path')
echo "$FILE" | grep -qE '\.dart$' || exit 0

if ! out=$(fvm dart format "$FILE" 2>&1); then
  printf '%s\n' "$out" | head -5
  exit 1
fi
