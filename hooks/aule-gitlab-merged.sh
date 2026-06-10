#!/bin/bash
# Usage: aule-gitlab-merged.sh <mr-url>
# Reports whether a GitLab MR has merged, for Aulë's close-on-merge sweep.
# On merged:     merged: commit=<sha> url=<mr-url>
# On not merged: unmerged: state=<opened|closed|locked>
# On failure:    {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.
# This hook does not handle credential resolution beyond what `glab` does on its own.

set -euo pipefail
export LC_ALL=C.UTF-8

MR_URL="${1:-}"
if [[ -z "$MR_URL" ]]; then
  echo '{"error":"usage: aule-gitlab-merged.sh <mr-url>"}'
  exit 1
fi

if ! command -v glab >/dev/null 2>&1; then
  echo '{"error":"glab CLI not found on PATH"}'
  exit 1
fi

view_log=$(mktemp)
trap 'rm -f "$view_log"' EXIT
if ! glab mr view "$MR_URL" -F json >"$view_log" 2>&1; then
  jq -cn --arg u "$MR_URL" --rawfile r "$view_log" \
    '{error: ("glab mr view failed for " + $u), response: $r}'
  exit 1
fi

state=$(jq -r '.state // ""' "$view_log")
commit=$(jq -r '.merge_commit_sha // .squash_commit_sha // ""' "$view_log")

if [[ "$state" == "merged" ]]; then
  printf 'merged: commit=%s url=%s\n' "${commit:-?}" "$MR_URL"
else
  # glab state is opened|closed|locked|merged; pass the non-merged ones through.
  printf 'unmerged: state=%s\n' "${state:-unknown}"
fi
