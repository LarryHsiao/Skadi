#!/bin/bash
# Usage: aule-github-merged.sh <pr-url>
# Reports whether a GitHub PR has merged, for Aulë's close-on-merge sweep.
# On merged:     merged: commit=<sha> url=<pr-url>
# On not merged: unmerged: state=<open|closed>
# On failure:    {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.
# This hook does not handle credential resolution beyond what `gh` does on its own.

set -euo pipefail
export LC_ALL=C.UTF-8

PR_URL="${1:-}"
if [[ -z "$PR_URL" ]]; then
  echo '{"error":"usage: aule-github-merged.sh <pr-url>"}'
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo '{"error":"gh CLI not found on PATH"}'
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo '{"error":"gh is not authenticated; run `gh auth login` first"}'
  exit 1
fi

view_log=$(mktemp)
trap 'rm -f "$view_log"' EXIT
if ! gh pr view "$PR_URL" --json state,mergeCommit >"$view_log" 2>&1; then
  jq -cn --arg u "$PR_URL" --rawfile r "$view_log" \
    '{error: ("gh pr view failed for " + $u), response: $r}'
  exit 1
fi

state=$(jq -r '.state // ""' "$view_log")
commit=$(jq -r '.mergeCommit.oid // ""' "$view_log")

if [[ "$state" == "MERGED" ]]; then
  printf 'merged: commit=%s url=%s\n' "${commit:-?}" "$PR_URL"
else
  # gh state is OPEN|CLOSED|MERGED; normalise the non-merged ones to lowercase.
  lower=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
  printf 'unmerged: state=%s\n' "${lower:-unknown}"
fi
