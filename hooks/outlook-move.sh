#!/bin/bash
# Usage: cat ids.txt | outlook-move.sh <folder-id> [account] [bw-item]
# Moves each Microsoft Graph message ID (one per line on stdin) to the named folder.
# Token from outlook-token.sh.
#
# Args:
#   folder-id  Required. Destination folder id.
#   account    Friendly account name for state path. Default: legacy flat path.
#   bw-item    Bitwarden item name for credentials. Default: outlook.
#
# stdout: "moved: <id>" per success.
# stderr: "failed: <id> <http_code>" per failure.
# Exit:   0 if all moved, 1 if any failed.

set -u

FOLDER_ID="${1:-}"
ACCOUNT="${2:-}"
BW_ITEM="${3:-outlook}"
if [[ -z "$FOLDER_ID" ]]; then
  echo "outlook-move: folder id required (arg 1)" >&2
  exit 1
fi

TOKEN=$("$(dirname "$0")/outlook-token.sh" "$ACCOUNT" "$BW_ITEM")
if [[ -z "$TOKEN" ]]; then
  echo "outlook-move: empty token" >&2
  exit 1
fi

GRAPH="https://graph.microsoft.com/v1.0/me/messages"
body=$(jq -n --arg dest "$FOLDER_ID" '{destinationId: $dest}')
any_fail=0

while IFS= read -r id; do
  id="${id%$'\r'}"
  [[ -z "$id" ]] && continue
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$GRAPH/$id/move" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    echo "moved: $id"
  else
    echo "failed: $id $code" >&2
    any_fail=1
  fi
done

exit "$any_fail"
