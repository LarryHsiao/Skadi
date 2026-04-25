#!/bin/bash
# Usage: glorfindel-youtrack-list.sh <PROJECT-KEY> [<EXTRA-QUERY>]
# Lists open tickets in a YouTrack project (default: state #Unresolved).
# If EXTRA-QUERY is given, it is appended to the project filter.
# Prints JSON array: [{"id":"MET-1","summary":"..."}]
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Pagination: pages of 50 via $top/$skip. Hard cap of MAX_PAGES * 50 = 1000
# tickets per call to bound the cost of a runaway sweep.

set -euo pipefail
export LC_ALL=C.UTF-8

PAGE_SIZE=50
MAX_PAGES=20

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

aggregate_file=$(mktemp)
page_file=$(mktemp)
trap 'rm -f "$aggregate_file" "$page_file"' EXIT
echo '[]' > "$aggregate_file"

skip=0
truncated=false
for ((page=0; page<MAX_PAGES; page++)); do
  status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
    -H "Authorization: Bearer $TOK" \
    -H "Accept: application/json" \
    --data-urlencode "query=$query" \
    --data-urlencode "fields=idReadable,summary" \
    --data-urlencode "\$top=$PAGE_SIZE" \
    --data-urlencode "\$skip=$skip" \
    "$URL/api/issues")

  if [[ "$status" != 2* ]]; then
    jq -cn --arg s "$status" --arg q "$query" --arg skip "$skip" --rawfile b "$page_file" \
      '{error: ("youtrack list failed (http=" + $s + ")"), query: $q, skip: $skip, response: $b}'
    exit 1
  fi

  page_count=$(jq 'length' "$page_file")
  if [[ "$page_count" -eq 0 ]]; then
    break
  fi

  jq -s '.[0] + (.[1] | map({id: .idReadable, summary: .summary}))' \
    "$aggregate_file" "$page_file" > "$aggregate_file.next"
  mv "$aggregate_file.next" "$aggregate_file"

  if [[ "$page_count" -lt "$PAGE_SIZE" ]]; then
    break
  fi

  skip=$((skip + PAGE_SIZE))

  if [[ "$page" -eq $((MAX_PAGES - 1)) ]]; then
    truncated=true
  fi
done

if $truncated; then
  jq --arg cap "$((MAX_PAGES * PAGE_SIZE))" \
    '{tickets: ., truncated: true, cap: ($cap | tonumber)}' "$aggregate_file"
else
  cat "$aggregate_file"
fi
