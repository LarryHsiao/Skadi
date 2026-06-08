#!/bin/bash
# Usage: echo "new body" | youtrack-comment-edit.sh <TICKET-ID> <COMMENT-ID>
# Replaces the text of an existing comment in place (modify, not append).
# Resolves YOUTRACK_URL / YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On success, prints: edited: id=<comment-id> url=<ticket-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Non-ASCII safety mirrors council-youtrack-comment.sh: body rides files, never argv.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
COMMENT_ID="${2:-}"
if [[ -z "$TICKET_ID" || -z "$COMMENT_ID" ]]; then
  echo '{"error":"usage: youtrack-comment-edit.sh <TICKET-ID> <COMMENT-ID>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
YOUTRACK_URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
if [[ -z "$YOUTRACK_URL" ]]; then
  echo '{"error":"YOUTRACK_URL not found (tried Vaultwarden item \"youtrack\" uri and $YOUTRACK_URL)"}'
  exit 1
fi
YOUTRACK_TOKEN="$("$SECRET" youtrack 2>/dev/null || true)"
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

payload_file=$(mktemp)
jq -n --rawfile text "$body_file" '{text: $text}' > "$payload_file"

response_file=$(mktemp)
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload_file" \
  "$URL/api/issues/$TICKET_ID/comments/$COMMENT_ID?fields=id")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$COMMENT_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("edit comment failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

printf 'edited: id=%s url=%s/issue/%s\n' "$COMMENT_ID" "$URL" "$TICKET_ID"
