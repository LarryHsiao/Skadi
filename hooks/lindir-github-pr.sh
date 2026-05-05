#!/bin/bash
# Usage:
#   lindir-github-pr.sh <pr-url>          # prints JSON brief (default)
#   lindir-github-pr.sh --diff <pr-url>   # prints raw unified diff to stdout
#
# JSON shape: {title, number, author, state, head, base, description, files:[{path,additions,deletions}]}
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.
# The host is derived from the URL itself; gh resolves the host from its config.

set -euo pipefail
export LC_ALL=C.UTF-8

MODE="json"
if [[ "${1:-}" == "--diff" ]]; then
  MODE="diff"
  shift
fi

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: lindir-github-pr.sh [--diff] <pr-url>"}'
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

# Parse owner/repo and PR number from the URL.
# Pattern: https?://<host>/<owner>/<repo>/pull/<n>
if [[ ! "$URL" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  jq -cn --arg u "$URL" '{error: ("not a github pull request URL: " + $u)}'
  exit 1
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"

# --diff mode: print raw unified diff and exit.
if [[ "$MODE" == "diff" ]]; then
  exec gh pr diff "$NUMBER" --repo "$OWNER/$REPO"
fi

view_log=$(mktemp)
files_log=$(mktemp)
trap 'rm -f "$view_log" "$files_log"' EXIT

if ! gh pr view "$NUMBER" \
      --repo "$OWNER/$REPO" \
      --json title,number,author,state,headRefName,baseRefName,body \
      >"$view_log" 2>&1; then
  jq -cn --arg u "$URL" --rawfile r "$view_log" \
    '{error: ("gh pr view failed for " + $u), response: $r}'
  exit 1
fi

# Files come from a separate API call; gh pr view does not expose per-file churn.
if ! gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/files" \
      >"$files_log" 2>&1; then
  jq -cn --arg u "$URL" --rawfile r "$files_log" \
    '{error: ("gh api pulls/files failed for " + $u), response: $r}'
  exit 1
fi

# Combine and shape the output. gh api --paginate streams concatenated JSON arrays;
# `jq -s add` merges them into one array.
jq -n \
  --slurpfile view "$view_log" \
  --slurpfile files_pages "$files_log" \
  '($view[0]) as $v
   | ($files_pages | add) as $files
   | {
       title: ($v.title // ""),
       number: ($v.number // 0),
       author: ($v.author.login // ""),
       state: ($v.state // ""),
       head: ($v.headRefName // ""),
       base: ($v.baseRefName // ""),
       description: ($v.body // ""),
       files: ($files | map({
         path: (.filename // ""),
         additions: (.additions // 0),
         deletions: (.deletions // 0)
       }))
     }'
