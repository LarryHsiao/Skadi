#!/bin/bash
# Usage: glorfindel-jira-list.sh <PROJECT-KEY> <FILTER>
# Lists issues in a Jira project matching the given filter.
#   FILTER (required):
#     - All-digits string (e.g. "10363") -> treat as saved filter ID:
#         jql = "filter = 10363"
#     - Otherwise -> treat as raw JQL fragment, ANDed with the project clause:
#         jql = "project = <KEY> AND <FILTER>"
# Prints JSON array: [{"id":"PSG-4264","summary":"..."}]
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Pagination: pages of 50 via maxResults + nextPageToken (Jira v3 cursor model).
# Hard cap of MAX_PAGES * 50 = 1000 issues per call to bound runaway sweeps.

set -euo pipefail
export LC_ALL=C.UTF-8

PAGE_SIZE=50
MAX_PAGES=20

PROJECT_KEY="${1:-}"
FILTER="${2:-}"

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"project key required"}'
  exit 1
fi

if [[ -z "$FILTER" ]]; then
  echo '{"error":"filter required (pass a saved-filter ID like 10363, or a raw JQL fragment)"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
URL="$("$SECRET" jira uri 2>/dev/null || true)"
EMAIL="$("$SECRET" jira username 2>/dev/null || true)"
TOK="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

if [[ -z "$URL" || -z "$EMAIL" || -z "$TOK" ]]; then
  echo '{"error":"jira credentials missing (need uri+username+password from Vaultwarden item \"jira\" or env)"}'
  exit 1
fi

URL="${URL%/}"

if [[ "$FILTER" =~ ^[0-9]+$ ]]; then
  jql="filter = $FILTER"
else
  jql="project = $PROJECT_KEY AND ($FILTER)"
fi

aggregate_file=$(mktemp)
page_file=$(mktemp)
trap 'rm -f "$aggregate_file" "$page_file"' EXIT
echo '[]' > "$aggregate_file"

next_token=""
truncated=false
for ((page=0; page<MAX_PAGES; page++)); do
  url_args=(
    --data-urlencode "jql=$jql"
    --data-urlencode "fields=summary"
    --data-urlencode "maxResults=$PAGE_SIZE"
  )
  if [[ -n "$next_token" ]]; then
    url_args+=( --data-urlencode "nextPageToken=$next_token" )
  fi

  status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
    -u "$EMAIL:$TOK" \
    -H "Accept: application/json" \
    "${url_args[@]}" \
    "$URL/rest/api/3/search/jql")

  if [[ "$status" != 2* ]]; then
    jq -cn --arg s "$status" --arg j "$jql" --arg page "$page" --rawfile b "$page_file" \
      '{error: ("jira list failed (http=" + $s + ") on page " + $page), jql: $j, response: $b}'
    exit 1
  fi

  page_count=$(jq '.issues | length' "$page_file")
  if [[ "$page_count" -gt 0 ]]; then
    jq -s '.[0] + (.[1].issues | map({id: .key, summary: .fields.summary}))' \
      "$aggregate_file" "$page_file" > "$aggregate_file.next"
    mv "$aggregate_file.next" "$aggregate_file"
  fi

  is_last=$(jq -r '.isLast // false' "$page_file")
  next_token=$(jq -r '.nextPageToken // ""' "$page_file")

  if [[ "$is_last" == "true" || -z "$next_token" ]]; then
    break
  fi

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
