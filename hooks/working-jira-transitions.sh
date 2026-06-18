#!/bin/bash
# Usage: working-jira-transitions.sh <ISSUE-KEY>
# Prints JSON array of the issue's available workflow transitions:
#   [{"id":"31","name":"In Progress","to":"In Progress"}]
#   to — the status name the transition lands in ("" when absent)
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3. On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
if [[ -z "$ISSUE_KEY" ]]; then
  echo '{"error":"usage: working-jira-transitions.sh <ISSUE-KEY>"}'
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

trans_file=$(mktemp)
trap 'rm -f "$trans_file"' EXIT

status=$(curl -sS -o "$trans_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/transitions")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$trans_file" \
    '{error: ("fetch transitions failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

jq -c '[(.transitions // [])[] | {id: .id, name: .name, to: (.to.name // "")}]' "$trans_file"
