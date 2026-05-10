#!/usr/bin/env bash
# amon-din-teamcity.sh — recent TeamCity builds for a buildType.
# Read-only (REST app/rest/builds).
#
# Usage:
#   amon-din-teamcity.sh <buildTypeId> [<count>] [<branch>]
#     buildTypeId — TeamCity build configuration id (required)
#     count       — number of builds (default 3)
#     branch      — branch name (optional; TeamCity locator value)
#
# Auth: reads URL + token from Bitwarden item "teamcity" via
#   ~/.claude/hooks/secret.sh teamcity uri
#   ~/.claude/hooks/secret.sh teamcity password
#
# Output (stdout): zero or more pipe-delimited lines
#   <number>|<status>|<branch>|<timestamp>|<url>
# where <status> is normalised to one of:
#   success | failed | running | queued | cancelled | unknown
#
# Errors print to stderr and exit non-zero. Tokens never appear in stdout.

set -u

BUILD_TYPE="${1:-}"
COUNT="${2:-3}"
BRANCH="${3:-}"

if [[ -z "$BUILD_TYPE" ]]; then
  echo "usage: amon-din-teamcity.sh <buildTypeId> [count] [branch]" >&2
  exit 1
fi

HERE="$(dirname "$0")"

TC_URL=$("$HERE/secret.sh" teamcity uri 2>/dev/null || true)
TC_TOKEN=$("$HERE/secret.sh" teamcity password 2>/dev/null || true)

if [[ -z "$TC_URL" || -z "$TC_TOKEN" ]]; then
  echo "teamcity credentials missing — Bitwarden item 'teamcity' must carry both URI and password" >&2
  exit 1
fi

TC_URL="${TC_URL%/}"

locator="buildType:$BUILD_TYPE,count:$COUNT"
[[ -n "$BRANCH" ]] && locator="$locator,branch:$BRANCH"

fields='build(number,status,state,branchName,finishOnAgentDate,webUrl)'

resp=$(curl -sS \
  -H "Authorization: Bearer $TC_TOKEN" \
  -H "Accept: application/json" \
  --get \
  --data-urlencode "locator=$locator" \
  --data-urlencode "fields=$fields" \
  "$TC_URL/app/rest/builds" 2>&1) || {
    echo "teamcity request failed: $resp" >&2
    exit 1
  }

# A non-JSON body (HTML error page, plain text) means the request did not land.
case "$resp" in
  '{'*) ;;
  *)
    echo "teamcity returned a non-JSON response (likely auth or URL error):" >&2
    echo "$resp" | head -c 400 >&2
    echo >&2
    exit 1
    ;;
esac

printf '%s' "$resp" | jq -r '
  (.build // [])
  | .[]
  | [
      (.number // ""),
      (
        if .state == "running" then "running"
        elif .state == "queued" then "queued"
        elif .status == "SUCCESS" then "success"
        elif .status == "FAILURE" then "failed"
        elif .status == "ERROR"   then "failed"
        elif .status == "UNKNOWN" then "cancelled"
        else "unknown"
        end
      ),
      (.branchName // ""),
      (.finishOnAgentDate // ""),
      (.webUrl // "")
    ]
  | @tsv
' | tr '\t' '|'
