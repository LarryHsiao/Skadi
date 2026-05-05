#!/bin/bash
# Usage: jira-state.sh <ISSUE-KEY> <TRANSITION-ID>
# Moves a Jira issue through transition <TRANSITION-ID>.
# Resolves Jira creds via secret.sh (vault first, env fallback).
#
# Idempotent: reads the issue's current status and the transition's `to.id`;
# if the issue is already in the transition's target status, prints a noop
# line and exits 0 without touching the tracker.
#
# On success (transition applied), prints:  transitioned: id=<key> status=<from>->\<to\> (transition=<id>)
# On no-op,                       prints:  noop: id=<key> status=<status>
# On failure, prints {"error":"...","response":"..."} (server body included) and exits non-zero.
#
# Why transition IDs and not status names: in Jira a status change requires a
# named workflow transition. Two transitions can land in the same status; only
# the project admin knows which one is "right" for a given action. Encoding the
# choice as the transition ID makes the call deterministic.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
TRANSITION_ID="${2:-}"
if [[ -z "$ISSUE_KEY" || -z "$TRANSITION_ID" ]]; then
  echo '{"error":"usage: jira-state.sh <ISSUE-KEY> <TRANSITION-ID>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
JIRA_URL="$("$SECRET" jira uri 2>/dev/null || true)"
JIRA_EMAIL="$("$SECRET" jira username 2>/dev/null || true)"
JIRA_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_TOKEN" ]]; then
  echo '{"error":"jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)"}'
  exit 1
fi

URL="${JIRA_URL%/}"

# 1. Read the current status and the available transitions for idempotency.
issue_response=$(mktemp)
trans_response=$(mktemp)
trap 'rm -f "$issue_response" "$trans_response" "${payload:-}" "${post_response:-}"' EXIT

issue_status=$(curl -sS -o "$issue_response" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY?fields=status")

if [[ "$issue_status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$issue_status" --rawfile b "$issue_response" \
    '{error: ("read status failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

current_status=$(jq -r '.fields.status.name // ""' "$issue_response")

trans_status=$(curl -sS -o "$trans_response" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/transitions")

if [[ "$trans_status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$trans_status" --rawfile b "$trans_response" \
    '{error: ("read transitions failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

target_status=$(jq -r --arg t "$TRANSITION_ID" '
  (.transitions // [])
  | map(select(.id == $t))
  | (.[0].to.name // "")
' "$trans_response")

if [[ -z "$target_status" ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg t "$TRANSITION_ID" --rawfile b "$trans_response" \
    '{error: ("transition " + $t + " is not available on " + $id), response: $b}'
  exit 1
fi

if [[ "$current_status" == "$target_status" ]]; then
  printf 'noop: id=%s status=%s\n' "$ISSUE_KEY" "$current_status"
  exit 0
fi

# 2. Apply the transition.
payload=$(mktemp)
jq -n --arg t "$TRANSITION_ID" '{transition: {id: $t}}' > "$payload"

post_response=$(mktemp)
post_status=$(curl -sS -X POST -o "$post_response" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/transitions")

if [[ "$post_status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$post_status" --rawfile b "$post_response" \
    '{error: ("transition failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

printf 'transitioned: id=%s status=%s->%s (transition=%s)\n' "$ISSUE_KEY" "${current_status:-?}" "$target_status" "$TRANSITION_ID"
