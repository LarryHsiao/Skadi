#!/bin/bash
# Usage: outlook-token.sh [account] [bw-item]
# Prints a valid Microsoft Graph access token to stdout for the given account.
# Handles token cache, refresh, and the device-code dance on first run.
#
# Args:
#   account  Friendly account name (e.g. "personal", "work"). Used for state
#            path. When empty, state lives at the legacy flat path
#            ~/.skadi/outlook/tokens.json (single-account compat).
#   bw-item  Bitwarden item name carrying client-id (username) and authority
#            (uri). Default: "outlook".

set -euo pipefail

ACCOUNT="${1:-}"
BW_ITEM="${2:-outlook}"
SECRET="$(dirname "$0")/secret.sh"
SCOPES="Mail.Read Mail.ReadWrite offline_access"

if [[ -n "$ACCOUNT" ]]; then
  CACHE_DIR="$HOME/.skadi/outlook/$ACCOUNT"
else
  CACHE_DIR="$HOME/.skadi/outlook"
fi
TOKEN_FILE="$CACHE_DIR/tokens.json"

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

CLIENT_ID="$("$SECRET" "$BW_ITEM" username -)"
AUTHORITY="$("$SECRET" "$BW_ITEM" uri -)"
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
    echo "outlook-token: device code request failed: $resp" >&2
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
      *) echo "outlook-token: token poll failed: $resp" >&2; exit 1 ;;
    esac
  done
  echo "outlook-token: device code expired before sign-in" >&2
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

access_token
