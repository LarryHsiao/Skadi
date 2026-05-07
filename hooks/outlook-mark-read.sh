#!/bin/bash
# Usage: cat ids.txt | outlook-mark-read.sh [account] [bw-item]
# Marks each Microsoft Graph message ID (one per line on stdin) as read.
# Token from outlook-token.sh.
#
# Args:
#   account  Friendly account name for state path. Default: legacy flat path.
#   bw-item  Bitwarden item name for credentials. Default: outlook.
#
# stdout: "read: <id>" per success.
# stderr: "failed: <id> <http_code>" per failure.
# Exit:   0 if all marked, 1 if any failed.

set -u

ACCOUNT="${1:-}"
BW_ITEM="${2:-outlook}"
TOKEN=$("$(dirname "$0")/outlook-token.sh" "$ACCOUNT" "$BW_ITEM")
if [[ -z "$TOKEN" ]]; then
  echo "outlook-mark-read: empty token" >&2
  exit 1
fi

GRAPH="https://graph.microsoft.com/v1.0/me/messages"
any_fail=0

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PATCH "$GRAPH/$id" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"isRead": true}')
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    echo "read: $id"
  else
    echo "failed: $id $code" >&2
    any_fail=1
  fi
done

exit "$any_fail"
