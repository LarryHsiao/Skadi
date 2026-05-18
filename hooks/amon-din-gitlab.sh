#!/usr/bin/env bash
# amon-din-gitlab.sh — recent GitLab pipelines for the cwd's project.
# Read-only (glab api).
#
# Usage:
#   amon-din-gitlab.sh [<count>] [<branch>]
#     count  — number of pipelines to fetch (default 3)
#     branch — branch name; if omitted, no branch filter
#
# Output (stdout): zero or more pipe-delimited lines
#   <id>|<status>|<branch>|<timestamp>|<url>
# where <status> is normalised to one of:
#   success | failed | running | queued | cancelled | unknown
#
# Errors print to stderr and exit non-zero. Tokens never appear in stdout.

set -u

COUNT="${1:-3}"
BRANCH="${2:-}"

if ! command -v glab >/dev/null 2>&1; then
  echo "glab CLI not found on PATH" >&2
  exit 1
fi

if ! glab auth status >/dev/null 2>&1; then
  echo "glab is not authenticated; run \`glab auth login\`" >&2
  exit 1
fi

# Derive the project path (group/.../project) from the cwd's origin remote.
remote_url=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$remote_url" ]]; then
  echo "no git origin remote — Amon Din cannot resolve the project" >&2
  exit 1
fi

# Strip scheme/host (https://host/ or git@host:) and any trailing .git
project_path=$(printf '%s' "$remote_url" \
  | sed -E 's#^[a-zA-Z]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')

if [[ -z "$project_path" ]]; then
  echo "could not parse GitLab project path from origin: $remote_url" >&2
  exit 1
fi

encoded=$(jq -rn --arg p "$project_path" '$p | @uri')

query="per_page=$COUNT"
[[ -n "$BRANCH" ]] && query="$query&ref=$(jq -rn --arg b "$BRANCH" '$b | @uri')"

api_log=$(mktemp)
trap 'rm -f "$api_log"' EXIT

if ! glab api "projects/$encoded/pipelines?$query" >"$api_log" 2>&1; then
  echo "glab api failed for projects/$project_path/pipelines:" >&2
  cat "$api_log" >&2
  exit 1
fi

jq -r '
  (if type == "array" then . else [] end)
  | .[]
  | [
      (.id | tostring),
      (
        if   .status == "success"                                               then "success"
        elif .status == "failed"                                                then "failed"
        elif .status == "running"                                               then "running"
        elif (.status == "pending" or .status == "manual" or .status == "scheduled" or .status == "preparing" or .status == "waiting_for_resource") then "queued"
        elif .status == "canceled"                                              then "cancelled"
        else                                                                         "unknown"
        end
      ),
      (.ref // ""),
      (.created_at // ""),
      (.web_url // "")
    ]
  | @tsv
' "$api_log" | tr '\t' '|'
