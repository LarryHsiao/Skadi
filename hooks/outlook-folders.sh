#!/bin/bash
# Usage: outlook-folders.sh [account] [bw-item]
# Lists the user's top-level mail folders from Microsoft Graph.
# Token from outlook-token.sh.
#
# Args:
#   account  Friendly account name for state path. Default: legacy flat path.
#   bw-item  Bitwarden item name for credentials. Default: outlook.
#
# stdout: one folder per line, "<id>\t<displayName>".
# Exit:   0 on success, 1 on token miss or HTTP failure.

set -u

ACCOUNT="${1:-}"
BW_ITEM="${2:-outlook}"
TOKEN=$("$(dirname "$0")/outlook-token.sh" "$ACCOUNT" "$BW_ITEM")
if [[ -z "$TOKEN" ]]; then
  echo "outlook-folders: empty token" >&2
  exit 1
fi

resp=$(curl -sS -G "https://graph.microsoft.com/v1.0/me/mailFolders" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "\$select=id,displayName" \
  --data-urlencode "\$top=100")

err=$(jq -r '.error.message // empty' <<<"$resp")
if [[ -n "$err" ]]; then
  echo "outlook-folders: $err" >&2
  exit 1
fi

jq -r '.value[] | "\(.id)\t\(.displayName)"' <<<"$resp"
