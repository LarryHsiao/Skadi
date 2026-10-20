#!/bin/bash
# Usage: working-youtrack-open.sh <PROJECT-KEY> [MAX]
# Lists the project's unresolved tickets, most-recently-updated first,
# for the /working ticket picker.
#   MAX — cap on rows returned (default 20)
# Prints JSON array: [{"key":"MET-42","status":"In Progress","summary":"..."}]
# Same output contract as working-jira-open.sh; status is the State custom field.
# Resolves YOUTRACK_URL and YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

PROJECT_KEY="${1:-}"
MAX="${2:-20}"

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"usage: working-youtrack-open.sh <PROJECT-KEY> [MAX]"}'
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
query="project: $PROJECT_KEY #Unresolved sort by: updated desc"

page_file=$(mktemp)
trap 'rm -f "$page_file"' EXIT

status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
  -H "Authorization: Bearer $TOK" \
  -H "Accept: application/json" \
  --data-urlencode "query=$query" \
  --data-urlencode "fields=idReadable,summary,customFields(name,value(name))" \
  --data-urlencode "\$top=$MAX" \
  "$URL/api/issues")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg q "$query" --rawfile b "$page_file" \
    '{error: ("youtrack open-list failed (http=" + $s + ")"), query: $q, response: $b}'
  exit 1
fi

jq -c '[.[] | {
  key: .idReadable,
  status: ((.customFields // []) | map(select(.name == "State")) | .[0].value.name // ""),
  summary: (.summary // "")
}]' "$page_file"
