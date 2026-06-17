#!/bin/bash
# Usage: rhovanion-youtrack-probe.sh <PROJECT-KEY> <FILTER> [CURSOR-MS]
# Cheap movement probe for one YouTrack project: counts in-scope issues whose
# `updated` timestamp is newer than CURSOR-MS. This is Rhovanion's gate — it
# rides /anduin for a project only when this prints a count > 0.
#   FILTER (required): saved-query ID (digits-hyphen-digits, e.g. "11-0") or a
#     raw query fragment (e.g. "#Unresolved") — resolved exactly as the
#     glorfindel-youtrack-list hook resolves it.
#   CURSOR-MS (optional): epoch milliseconds of the project's last ride. Absent
#     or "0" means cold start — every in-scope issue counts as moved.
# Prints a single integer (issues updated since the cursor, capped at one page).
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# One page only, sorted newest-first: the count is exact while fewer than
# PAGE_SIZE issues moved, and saturates at PAGE_SIZE when more did — either way
# the gate reads "> 0 means ride". A saturated page means the project is busy
# and will ride regardless, so the lost precision costs nothing.

set -euo pipefail
export LC_ALL=C.UTF-8

PAGE_SIZE=50

PROJECT_KEY="${1:-}"
FILTER="${2:-}"
CURSOR_MS="${3:-0}"
[[ -z "$CURSOR_MS" ]] && CURSOR_MS=0

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"project key required"}'
  exit 1
fi

if [[ -z "$FILTER" ]]; then
  echo '{"error":"filter required (pass a saved-query ID like 11-0, or a raw query fragment)"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
TOK="$("$SECRET" youtrack 2>/dev/null || true)"

if [[ -z "$URL" || -z "$TOK" ]]; then
  echo '{"error":"YouTrack credentials missing (need uri+password from Vaultwarden item \"youtrack\" or env)"}'
  exit 1
fi

URL="${URL%/}"

if [[ "$FILTER" =~ ^[0-9]+-[0-9]+$ ]]; then
  saved_file=$(mktemp)
  saved_status=$(curl -sS -o "$saved_file" -w "%{http_code}" \
    -H "Authorization: Bearer $TOK" \
    -H "Accept: application/json" \
    "$URL/api/savedQueries/$FILTER?fields=name,query")
  if [[ "$saved_status" != 2* ]]; then
    jq -cn --arg id "$FILTER" --arg s "$saved_status" --rawfile b "$saved_file" \
      '{error: ("youtrack saved-query lookup failed for " + $id + " (http=" + $s + ")"), response: $b}'
    rm -f "$saved_file"
    exit 1
  fi
  filter_text=$(jq -r '.query // ""' "$saved_file")
  rm -f "$saved_file"
  if [[ -z "$filter_text" ]]; then
    jq -cn --arg id "$FILTER" '{error: ("youtrack saved query " + $id + " has no query text")}'
    exit 1
  fi
  query="project: $PROJECT_KEY $filter_text sort by: updated desc"
else
  query="project: $PROJECT_KEY $FILTER sort by: updated desc"
fi

page_file=$(mktemp)
trap 'rm -f "$page_file"' EXIT

status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
  -H "Authorization: Bearer $TOK" \
  -H "Accept: application/json" \
  --data-urlencode "query=$query" \
  --data-urlencode "fields=idReadable,updated" \
  --data-urlencode "\$top=$PAGE_SIZE" \
  "$URL/api/issues")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg q "$query" --rawfile b "$page_file" \
    '{error: ("youtrack probe failed (http=" + $s + ")"), query: $q, response: $b}'
  exit 1
fi

jq --argjson cursor "$CURSOR_MS" '[.[] | select((.updated // 0) > $cursor)] | length' "$page_file"
