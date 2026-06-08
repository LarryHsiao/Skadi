#!/bin/bash
# Usage: youtrack-attach.sh <TICKET-ID> <FILE-PATH>
# Attaches FILE to the issue, replacing any existing attachment of the same name
# (so a re-rendered skeleton PNG does not stack). Resolves creds via secret.sh.
# On success, prints: attached: name=<filename> id=<attachment-id> url=<ticket-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
FILE_PATH="${2:-}"
if [[ -z "$TICKET_ID" || -z "$FILE_PATH" ]]; then
  echo '{"error":"usage: youtrack-attach.sh <TICKET-ID> <FILE-PATH>"}'
  exit 1
fi
if [[ ! -f "$FILE_PATH" ]]; then
  echo "{\"error\":\"file not found: $FILE_PATH\"}"
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
YOUTRACK_URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
[[ -z "$YOUTRACK_URL" ]] && { echo '{"error":"YOUTRACK_URL not found"}'; exit 1; }
YOUTRACK_TOKEN="$("$SECRET" youtrack 2>/dev/null || true)"
[[ -z "$YOUTRACK_TOKEN" ]] && { echo '{"error":"YOUTRACK_TOKEN not found"}'; exit 1; }

URL="${YOUTRACK_URL%/}"
NAME="$(basename "$FILE_PATH")"

list_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$list_file" "$response_file"' EXIT

# 1. Find and delete any prior attachment of the same name (replace-in-place).
status=$(curl -sS -o "$list_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID/attachments?fields=id,name")
if [[ "$status" == 2* ]]; then
  while IFS= read -r old_id; do
    [[ -n "$old_id" ]] && curl -sS -o /dev/null -X DELETE \
      -H "Authorization: Bearer $YOUTRACK_TOKEN" \
      "$URL/api/issues/$TICKET_ID/attachments/$old_id" || true
  done < <(jq -r --arg n "$NAME" '.[] | select(.name == $n) | .id' "$list_file")
fi

# 2. Upload the new file (multipart).
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Accept: application/json" \
  -F "file=@$FILE_PATH;type=image/png" \
  "$URL/api/issues/$TICKET_ID/attachments?fields=id,name")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("attach failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

att_id=$(jq -r '.[0].id // .id // ""' "$response_file")
printf 'attached: name=%s id=%s url=%s/issue/%s\n' "$NAME" "$att_id" "$URL" "$TICKET_ID"
