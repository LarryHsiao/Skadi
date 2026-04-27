#!/usr/bin/env bash
# session-readme.sh — on SessionStart, inject the project's README.md as
# additional context so Claude opens each session already knowing what the
# project is. Silent if no README.md exists at the project root.

set -u

readme="${CLAUDE_PROJECT_DIR:-$PWD}/README.md"
[[ -f "$readme" ]] || exit 0

contents=$(cat "$readme") || exit 0
[[ -n "$contents" ]] || exit 0

framed="Project README (${readme}):

${contents}"

jq -n --arg ctx "$framed" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
