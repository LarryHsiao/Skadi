#!/bin/bash
# Usage: council-youtrack-fetch.sh <TICKET-ID>
# Prints JSON: {summary, description, comments:[{author,login,text,created}]}
# Resolves YOUTRACK_URL and YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On failure, prints {"error":"...","response":"..."} (server body included) and exits non-zero.
#
# Non-ASCII safety: response JSON may carry user-authored text. We feed it to jq via
# --slurpfile / --rawfile (filesystem) to avoid Windows argv cp1252 transcoding.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
if [[ -z "$TICKET_ID" ]]; then
  echo '{"error":"ticket id required"}'
  exit 1
fi

YOUTRACK_URL="$("$(dirname "$0")/secret.sh" youtrack uri 2>/dev/null || true)"
if [[ -z "$YOUTRACK_URL" ]]; then
  echo '{"error":"YOUTRACK_URL not found (tried Vaultwarden item \"youtrack\" uri and $YOUTRACK_URL)"}'
  exit 1
fi

YOUTRACK_TOKEN="$("$(dirname "$0")/secret.sh" youtrack 2>/dev/null || true)"
if [[ -z "$YOUTRACK_TOKEN" ]]; then
  echo '{"error":"YOUTRACK_TOKEN not found (tried Vaultwarden item \"youtrack\" password and $YOUTRACK_TOKEN)"}'
  exit 1
fi

URL="${YOUTRACK_URL%/}"

issue_file=$(mktemp)
comments_file=$(mktemp)
trap 'rm -f "$issue_file" "$comments_file"' EXIT

fetch_to_file() {
  local label="$1" path="$2" out="$3"
  local status
  status=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "Authorization: Bearer $YOUTRACK_TOKEN" \
    -H "Accept: application/json" \
    "$URL$path")
  if [[ "$status" != 2* ]]; then
    jq -cn --arg label "$label" --arg id "$TICKET_ID" --arg s "$status" --rawfile b "$out" \
      '{error: ("fetch " + $label + " failed for " + $id + " (http=" + $s + ")"), response: $b}'
    return 1
  fi
}

if ! fetch_to_file "issue" "/api/issues/$TICKET_ID?fields=summary,description" "$issue_file"; then
  exit 1
fi
if ! fetch_to_file "comments" "/api/issues/$TICKET_ID/comments?fields=text,author(name,login),created&\$top=200" "$comments_file"; then
  exit 1
fi

jq -n \
  --slurpfile issue_arr "$issue_file" \
  --slurpfile comments_arr "$comments_file" \
  '($issue_arr[0]) as $issue | ($comments_arr[0]) as $comments | {
    summary: ($issue.summary // ""),
    description: ($issue.description // ""),
    comments: ($comments | map({
      author: (.author.name // ""),
      login: (.author.login // ""),
      text: (.text // ""),
      created: (.created // 0)
    }))
  }'
