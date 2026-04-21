#!/usr/bin/env bash
# Manage the stored publish target for the /publish-macos skill.
# Target is stored per-project in ./.claude/publish-macos-target.
#
# Usage:
#   publish-macos-target.sh get                      # print stored target, or empty
#   publish-macos-target.sh set <github|app-store>   # persist target

set -euo pipefail

TARGET_FILE=".claude/publish-macos-target"

case "${1:-}" in
  get)
    if [[ -f "$TARGET_FILE" ]]; then
      cat "$TARGET_FILE"
    fi
    ;;
  set)
    value="${2:-}"
    case "$value" in
      github|app-store) ;;
      *)
        echo "Invalid target: '$value' (expected 'github' or 'app-store')" >&2
        exit 1
        ;;
    esac
    mkdir -p "$(dirname "$TARGET_FILE")"
    printf '%s\n' "$value" > "$TARGET_FILE"
    ;;
  *)
    echo "Usage: $0 {get|set} [github|app-store]" >&2
    exit 1
    ;;
esac
