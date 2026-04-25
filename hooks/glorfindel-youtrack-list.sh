#!/bin/bash
# Usage: glorfindel-youtrack-list.sh <PROJECT-KEY> [<EXTRA-QUERY>]
# Lists open tickets in a YouTrack project (default: state #Unresolved).
# If EXTRA-QUERY is given, it is appended to the project filter.
# Prints JSON array: [{"id":"MET-1","summary":"..."}]
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

PROJECT_KEY="${1:-}"
EXTRA_QUERY="${2:-}"

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"project key required"}'
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

if [[ -n "$EXTRA_QUERY" ]]; then
  query="project: $PROJECT_KEY $EXTRA_QUERY"
else
  query="project: $PROJECT_KEY #Unresolved"
fi

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

status=$(curl -sS -G -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $TOK" \
  -H "Accept: application/json" \
  --data-urlencode "query=$query" \
  --data-urlencode "fields=idReadable,summary" \
  --data-urlencode '$top=200' \
  "$URL/api/issues")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg q "$query" --rawfile b "$response_file" \
    '{error: ("youtrack list failed (http=" + $s + ")"), query: $q, response: $b}'
  exit 1
fi

jq '[.[] | {id: .idReadable, summary: .summary}]' "$response_file"
