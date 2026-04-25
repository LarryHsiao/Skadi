#!/bin/bash
# Usage: echo "body text" | council-youtrack-comment.sh <TICKET-ID>
# Posts the comment body (read from stdin) on the ticket.
# Env: YOUTRACK_URL (required), YOUTRACK_TOKEN (required)
# On success, prints one line: posted: id=<id> created=<epoch-ms>
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

body=$(cat)
if [[ -z "$body" ]]; then
  echo '{"error":"empty comment body on stdin"}'
  exit 1
fi

payload=$(jq -n --arg text "$body" '{text: $text}')

response=$(curl -sS -f \
  -X POST \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "$payload" \
  "$URL/api/issues/$TICKET_ID/comments?fields=id,created" 2>/dev/null) || {
    echo "{\"error\":\"post comment failed for $TICKET_ID\"}"
    exit 1
  }

echo "$response" | jq -r '"posted: id=\(.id) created=\(.created)"'
