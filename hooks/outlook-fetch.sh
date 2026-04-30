#!/bin/bash
# Usage: outlook-fetch.sh [hours]
# Fetches unread mail from Outlook (Microsoft Graph) within the given window.
# Default window: 24 hours. First run triggers device-code sign-in.

set -euo pipefail

HOURS="${1:-24}"
SECRET="$(dirname "$0")/secret.sh"
CACHE_DIR="$HOME/.skadi/outlook"
TOKEN_FILE="$CACHE_DIR/tokens.json"
SCOPES="Mail.Read Mail.ReadWrite offline_access"

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

CLIENT_ID="$("$SECRET" outlook username -)"
AUTHORITY="$("$SECRET" outlook uri -)"
AUTHORITY="${AUTHORITY%/}"

DEVICECODE_URL="$AUTHORITY/oauth2/v2.0/devicecode"
TOKEN_URL="$AUTHORITY/oauth2/v2.0/token"

now() { date +%s; }

write_tokens() {
  local resp="$1" access expires refresh exp_at
  access=$(jq -r '.access_token' <<<"$resp")
  expires=$(jq -r '.expires_in' <<<"$resp")
  refresh=$(jq -r '.refresh_token // empty' <<<"$resp")
  if [[ -z "$refresh" && -f "$TOKEN_FILE" ]]; then
    refresh=$(jq -r '.refresh_token // empty' "$TOKEN_FILE")
  fi
  exp_at=$(( $(now) + expires - 60 ))
  jq -n --arg a "$access" --arg r "$refresh" --argjson e "$exp_at" \
    '{access_token: $a, refresh_token: $r, expires_at: $e}' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

device_code_dance() {
  local resp device_code user_code verification_uri interval expires_in deadline err
  resp=$(curl -sS -X POST "$DEVICECODE_URL" \
    -d "client_id=$CLIENT_ID" \
    --data-urlencode "scope=$SCOPES")
  device_code=$(jq -r '.device_code // empty' <<<"$resp")
  if [[ -z "$device_code" ]]; then
    echo "outlook-fetch: device code request failed: $resp" >&2
    exit 1
  fi
  user_code=$(jq -r '.user_code' <<<"$resp")
  verification_uri=$(jq -r '.verification_uri' <<<"$resp")
  interval=$(jq -r '.interval // 5' <<<"$resp")
  expires_in=$(jq -r '.expires_in // 900' <<<"$resp")

  echo "Open: $verification_uri" >&2
  echo "Code: $user_code" >&2
  echo "(waiting for sign-in)" >&2

  deadline=$(( $(now) + expires_in ))
  while (( $(now) < deadline )); do
    sleep "$interval"
    resp=$(curl -sS -X POST "$TOKEN_URL" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      -d "client_id=$CLIENT_ID" \
      -d "device_code=$device_code")
    err=$(jq -r '.error // empty' <<<"$resp")
    if [[ -z "$err" ]]; then
      write_tokens "$resp"
      return 0
    fi
    case "$err" in
      authorization_pending|slow_down) continue ;;
      *) echo "outlook-fetch: token poll failed: $resp" >&2; exit 1 ;;
    esac
  done
  echo "outlook-fetch: device code expired before sign-in" >&2
  exit 1
}

access_token() {
  local exp_at refresh resp err
  if [[ -f "$TOKEN_FILE" ]]; then
    exp_at=$(jq -r '.expires_at // 0' "$TOKEN_FILE")
    if (( $(now) < exp_at )); then
      jq -r '.access_token' "$TOKEN_FILE"
      return 0
    fi
    refresh=$(jq -r '.refresh_token // empty' "$TOKEN_FILE")
    if [[ -n "$refresh" ]]; then
      resp=$(curl -sS -X POST "$TOKEN_URL" \
        -d "grant_type=refresh_token" \
        -d "client_id=$CLIENT_ID" \
        -d "refresh_token=$refresh" \
        --data-urlencode "scope=$SCOPES")
      err=$(jq -r '.error // empty' <<<"$resp")
      if [[ -z "$err" ]]; then
        write_tokens "$resp"
        jq -r '.access_token' "$TOKEN_FILE"
        return 0
      fi
    fi
  fi
  device_code_dance
  jq -r '.access_token' "$TOKEN_FILE"
}

TOKEN=$(access_token)

SINCE=$(date -u -v-"${HOURS}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
     || date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")

curl -sS -G "https://graph.microsoft.com/v1.0/me/messages" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "\$filter=isRead eq false and receivedDateTime ge $SINCE" \
  --data-urlencode "\$select=id,subject,from,receivedDateTime,bodyPreview,importance,webLink" \
  --data-urlencode "\$orderby=receivedDateTime desc" \
  --data-urlencode "\$top=50"
