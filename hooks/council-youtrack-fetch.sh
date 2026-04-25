#!/bin/bash
# Usage: council-youtrack-fetch.sh <TICKET-ID>
# Prints JSON: {summary, description, comments:[{author,login,text,created}]}
# Env: YOUTRACK_URL (required), YOUTRACK_TOKEN (required)
# On failure, prints {"error":"..."} to stdout and exits non-zero.

set -euo pipefail

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

issue=$(curl -sS -f \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID?fields=summary,description" 2>/dev/null) || {
    echo "{\"error\":\"fetch issue failed for $TICKET_ID\"}"
    exit 1
  }

comments=$(curl -sS -f \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID/comments?fields=text,author(name,login),created&\$top=200" 2>/dev/null) || {
    echo "{\"error\":\"fetch comments failed for $TICKET_ID\"}"
    exit 1
  }

jq -n \
  --argjson issue "$issue" \
  --argjson comments "$comments" \
  '{
    summary: ($issue.summary // ""),
    description: ($issue.description // ""),
    comments: ($comments | map({
      author: (.author.name // ""),
      login: (.author.login // ""),
      text: (.text // ""),
      created: (.created // 0)
    }))
  }'
