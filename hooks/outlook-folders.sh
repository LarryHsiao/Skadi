#!/bin/bash
# Usage: outlook-folders.sh
# Lists the user's top-level mail folders from Microsoft Graph.
# Token from outlook-token.sh.
#
# stdout: one folder per line, "<id>\t<displayName>".
# Exit:   0 on success, 1 on token miss or HTTP failure.

set -u

TOKEN=$("$(dirname "$0")/outlook-token.sh")
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
