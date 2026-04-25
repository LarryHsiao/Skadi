#!/bin/bash
# Usage: echo "body text" | council-youtrack-comment.sh <TICKET-ID>
# Posts the comment body (read from stdin) on the ticket.
# Resolves YOUTRACK_URL and YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On success, prints one line: posted: id=<id> created=<epoch-ms> url=<ticket-url>
# On failure, prints {"error":"...","response":"..."} (server body included) and exits non-zero.
#
# Non-ASCII safety: jq.exe and curl.exe on Windows transcode argv through cp1252,
# which corrupts UTF-8 bytes. We pass the body via files (jq --rawfile, curl -d @file)
# so no non-ASCII payload ever rides on argv.

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

body_raw=$(cat)
if [[ -z "$body_raw" ]]; then
  echo '{"error":"empty comment body on stdin"}'
  exit 1
fi

# Stage body in a tempfile and normalize to UTF-8 (some shells deliver cp1252).
body_file=$(mktemp)
trap 'rm -f "$body_file" "${payload_file:-}" "${response_file:-}"' EXIT
printf '%s' "$body_raw" > "$body_file"
if ! iconv -f UTF-8 -t UTF-8 "$body_file" >/dev/null 2>&1; then
  if iconv -f WINDOWS-1252 -t UTF-8 "$body_file" > "$body_file.utf8" 2>/dev/null; then
    mv "$body_file.utf8" "$body_file"
  else
    echo '{"error":"comment body is neither valid UTF-8 nor CP1252"}'
    exit 1
  fi
fi

# Build JSON payload via --rawfile (filesystem, not argv).
payload_file=$(mktemp)
jq -n --rawfile text "$body_file" '{text: $text}' > "$payload_file"

# POST via -d @file (filesystem, not argv).
response_file=$(mktemp)
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload_file" \
  "$URL/api/issues/$TICKET_ID/comments?fields=id,created")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("post comment failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

jq -r --arg url "$URL" --arg ticket "$TICKET_ID" \
  '"posted: id=\(.id) created=\(.created) url=\($url)/issue/\($ticket)"' "$response_file"
