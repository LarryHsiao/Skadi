#!/bin/bash
# Usage: outlook-fetch.sh [hours] [account] [bw-item]
# Fetches unread inbox mail from Outlook (Microsoft Graph) within the window.
# Default window: 24 hours. Token machinery lives in outlook-token.sh.
#
# Args:
#   hours    Window of receivedDateTime to fetch. Default: 24.
#   account  Friendly account name for state path. Default: legacy flat path.
#   bw-item  Bitwarden item name for credentials. Default: outlook.

set -euo pipefail

HOURS="${1:-24}"
ACCOUNT="${2:-}"
BW_ITEM="${3:-outlook}"
TOKEN=$("$(dirname "$0")/outlook-token.sh" "$ACCOUNT" "$BW_ITEM")

SINCE=$(date -u -v-"${HOURS}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
     || date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")

curl -sS -G "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "\$filter=isRead eq false and receivedDateTime ge $SINCE" \
  --data-urlencode "\$select=id,subject,from,receivedDateTime,bodyPreview,importance,webLink" \
  --data-urlencode "\$orderby=receivedDateTime desc" \
  --data-urlencode "\$top=50"
