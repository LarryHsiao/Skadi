#!/bin/bash
# Usage: youtrack-state.sh <TICKET-ID> <STATE-NAME>
# Moves a YouTrack issue's State field to <STATE-NAME>.
# Resolves YOUTRACK_URL and YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
#
# Idempotent: reads the issue's current State first; if already at the target,
# prints a noop line and exits 0 without touching the tracker.
#
# On success (transition applied), prints:  transitioned: id=<id> state=<from>->\<to\>
# On no-op,                       prints:  noop: id=<id> state=<state>
# On failure, prints {"error":"...","response":"..."} (server body included) and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
TARGET_STATE="${2:-}"
if [[ -z "$TICKET_ID" || -z "$TARGET_STATE" ]]; then
  echo '{"error":"usage: youtrack-state.sh <TICKET-ID> <STATE-NAME>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
YOUTRACK_URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
if [[ -z "$YOUTRACK_URL" ]]; then
  echo '{"error":"YOUTRACK_URL not found (tried Vaultwarden item \"youtrack\" uri and $YOUTRACK_URL)"}'
  exit 1
fi

YOUTRACK_TOKEN="$("$SECRET" youtrack 2>/dev/null || true)"
if [[ -z "$YOUTRACK_TOKEN" ]]; then
  echo '{"error":"YOUTRACK_TOKEN not found (tried Vaultwarden item \"youtrack\" password and $YOUTRACK_TOKEN)"}'
  exit 1
fi

URL="${YOUTRACK_URL%/}"

# 1. Read the current State for idempotency.
read_response=$(mktemp)
trap 'rm -f "$read_response" "${cmd_payload:-}" "${cmd_response:-}"' EXIT

read_status=$(curl -sS -o "$read_response" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID?fields=customFields(name,value(name))")

if [[ "$read_status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$read_status" --rawfile b "$read_response" \
    '{error: ("read state failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

current_state=$(jq -r '
  (.customFields // [])
  | map(select(.name == "State"))
  | (.[0].value.name // "")
' "$read_response")

if [[ "$current_state" == "$TARGET_STATE" ]]; then
  printf 'noop: id=%s state=%s\n' "$TICKET_ID" "$current_state"
  exit 0
fi

# 2. Issue the State command.
cmd_payload=$(mktemp)
jq -n --arg q "State $TARGET_STATE" --arg id "$TICKET_ID" \
  '{query: $q, issues: [{idReadable: $id}]}' > "$cmd_payload"

cmd_response=$(mktemp)
cmd_status=$(curl -sS -X POST -o "$cmd_response" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$cmd_payload" \
  "$URL/api/commands")

if [[ "$cmd_status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$cmd_status" --rawfile b "$cmd_response" \
    '{error: ("state command failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

printf 'transitioned: id=%s state=%s->%s\n' "$TICKET_ID" "${current_state:-?}" "$TARGET_STATE"
