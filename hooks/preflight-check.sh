#!/usr/bin/env bash
# Preflight check — reports periodic maintenance status.
# Output: pipe-delimited `check|status|detail|flag`
#   flag = `warn` when a row should be highlighted.

set -euo pipefail

now=$(date +%s)

# --- cleanup-dev ---
cleanup_state="$HOME/.claude/.cleanup-dev-last-run"
if [ -f "$cleanup_state" ]; then
  last=$(cat "$cleanup_state" 2>/dev/null || echo "")
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    days=$(( (now - last) / 86400 ))
    date_str=$(date -r "$last" +%Y-%m-%d 2>/dev/null || echo "unknown")
    flag=""
    [ "$days" -gt 30 ] && flag="warn"
    echo "cleanup-dev|${days} days ago|last run ${date_str}|${flag}"
  else
    echo "cleanup-dev|unreadable|state file corrupt|warn"
  fi
else
  echo "cleanup-dev|never|no record|warn"
fi
