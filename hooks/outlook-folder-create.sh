#!/bin/bash
# Usage: outlook-folder-create.sh <name> [account] [bw-item]
# Creates a top-level mail folder via Microsoft Graph.
# Token from outlook-token.sh.
#
# Args:
#   name     Display name for the new folder. Required.
#   account  Friendly account name for state path. Default: legacy flat path.
#   bw-item  Bitwarden item name for credentials. Default: outlook.
#
# stdout: the new folder's id.
# Exit:   0 on success, 1 on missing name, token miss, or HTTP failure.

set -u

NAME="${1:-}"
ACCOUNT="${2:-}"
BW_ITEM="${3:-outlook}"

if [[ -z "$NAME" ]]; then
  echo "outlook-folder-create: name required" >&2
  exit 1
fi

TOKEN=$("$(dirname "$0")/outlook-token.sh" "$ACCOUNT" "$BW_ITEM")
if [[ -z "$TOKEN" ]]; then
  echo "outlook-folder-create: empty token" >&2
  exit 1
fi

body=$(jq -n --arg name "$NAME" '{displayName: $name}')

resp=$(curl -sS -X POST "https://graph.microsoft.com/v1.0/me/mailFolders" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$body")

err=$(jq -r '.error.message // empty' <<<"$resp")
if [[ -n "$err" ]]; then
  echo "outlook-folder-create: $err" >&2
  exit 1
fi

id=$(jq -r '.id // empty' <<<"$resp")
if [[ -z "$id" ]]; then
  echo "outlook-folder-create: no id in response" >&2
  exit 1
fi

echo "$id"
