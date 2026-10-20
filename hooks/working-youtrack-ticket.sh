#!/bin/bash
# Usage: working-youtrack-ticket.sh <TICKET-ID>
# Prints JSON: {summary, status, type, priority, description}
#   status, type, priority — the State, Type, Priority custom fields ("" when absent)
#   description — YouTrack markdown, passed through as-is ("" when absent)
# Same output contract as working-jira-ticket.sh, so /working's brief is tracker-blind.
# Resolves YOUTRACK_URL and YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
if [[ -z "$TICKET_ID" ]]; then
  echo '{"error":"usage: working-youtrack-ticket.sh <TICKET-ID>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
TOK="$("$SECRET" youtrack 2>/dev/null || true)"

if [[ -z "$URL" || -z "$TOK" ]]; then
  echo '{"error":"YouTrack credentials missing (need uri+password from Vaultwarden item \"youtrack\" or env)"}'
  exit 1
fi

URL="${URL%/}"

issue_file=$(mktemp)
trap 'rm -f "$issue_file"' EXIT

status=$(curl -sS -o "$issue_file" -w "%{http_code}" \
  -H "Authorization: Bearer $TOK" \
  -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID?fields=summary,description,customFields(name,value(name))")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$status" --rawfile b "$issue_file" \
    '{error: ("fetch issue failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

jq -c '
  def field($n): ((.customFields // []) | map(select(.name == $n)) | .[0].value.name // "");
  {
    summary: (.summary // ""),
    status: field("State"),
    type: field("Type"),
    priority: field("Priority"),
    description: (.description // "")
  }
' "$issue_file"
