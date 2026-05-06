#!/bin/bash
# Usage: outlook-fetch.sh [hours]
# Fetches unread mail from Outlook (Microsoft Graph) within the given window.
# Default window: 24 hours. Token machinery lives in outlook-token.sh.

set -euo pipefail

HOURS="${1:-24}"
TOKEN=$("$(dirname "$0")/outlook-token.sh")

SINCE=$(date -u -v-"${HOURS}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
     || date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")

curl -sS -G "https://graph.microsoft.com/v1.0/me/messages" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "\$filter=isRead eq false and receivedDateTime ge $SINCE" \
  --data-urlencode "\$select=id,subject,from,receivedDateTime,bodyPreview,importance,webLink" \
  --data-urlencode "\$orderby=receivedDateTime desc" \
  --data-urlencode "\$top=50"
