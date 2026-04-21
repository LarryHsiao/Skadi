#!/usr/bin/env bash
# cleanup-dev-project-scan.sh — find per-project build artifacts under $HOME.
# Output: pipe-delimited lines "size|path"
# Read-only. Excludes ~/Library and ~/.Trash. Max depth 5.
set -uo pipefail

find "$HOME" -maxdepth 5 -type d \
  \( -name node_modules -o -name .dart_tool -o -name build -o -name target -o -name .next \) \
  -not -path "$HOME/Library/*" \
  -not -path "$HOME/.Trash/*" \
  -not -path "$HOME/.Trash" \
  -prune 2>/dev/null | while IFS= read -r path; do
    size="$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
    printf "%s|%s\n" "${size:-?}" "$path"
  done | sort -hr
