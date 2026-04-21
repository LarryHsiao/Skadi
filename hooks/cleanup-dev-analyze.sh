#!/usr/bin/env bash
# cleanup-dev-analyze.sh — show largest top-level entries under a path.
# Read-only. Does not delete anything.
#
# Usage: cleanup-dev-analyze.sh [PATH] [LIMIT]
#   PATH   directory to analyze (default: $HOME)
#   LIMIT  max entries to return (default: 20)
#
# Output: pipe-delimited lines "size|path", sorted by size desc.
set -u

target="${1:-$HOME}"
limit="${2:-20}"

if [ ! -d "$target" ]; then
  echo "not a directory: $target" >&2
  exit 1
fi

target="$(cd "$target" 2>/dev/null && pwd)" || { echo "cannot resolve: $target" >&2; exit 1; }

# -x skips other filesystems — also prevents Git Bash from following NTFS
# junctions like "Application Data" under AppData into loops.
du -shx "$target"/* "$target"/.[!.]* 2>/dev/null \
  | sort -hr \
  | head -n "$limit" \
  | awk -F'\t' 'NF==2 {print $1"|"$2}'
