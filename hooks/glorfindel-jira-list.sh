#!/bin/bash
# Usage: glorfindel-jira-list.sh <PROJECT-KEY> [<FILTER>]
# Lists open issues in a Jira project.
#   FILTER (optional):
#     - All-digits string (e.g. "10363") -> treat as saved filter ID:
#         jql = "filter = 10363"
#     - Otherwise -> treat as raw JQL fragment, ANDed with the project clause:
#         jql = "project = <KEY> AND <FILTER>"
#     - If omitted -> default scope:
#         jql = "project = <KEY> AND statusCategory != Done"
# Prints JSON array: [{"id":"PSG-4264","summary":"..."}]
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

PROJECT_KEY="${1:-}"
FILTER="${2:-}"

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"project key required"}'
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

if [[ -z "$FILTER" ]]; then
  jql="project = $PROJECT_KEY AND statusCategory != Done"
elif [[ "$FILTER" =~ ^[0-9]+$ ]]; then
  jql="filter = $FILTER"
else
  jql="project = $PROJECT_KEY AND ($FILTER)"
fi

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

status=$(curl -sS -G -o "$response_file" -w "%{http_code}" \
  -u "$EMAIL:$TOK" \
  -H "Accept: application/json" \
  --data-urlencode "jql=$jql" \
  --data-urlencode "fields=summary" \
  --data-urlencode "maxResults=200" \
  "$URL/rest/api/3/search/jql")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg j "$jql" --rawfile b "$response_file" \
    '{error: ("jira list failed (http=" + $s + ")"), jql: $j, response: $b}'
  exit 1
fi

jq '[.issues[]? | {id: .key, summary: .fields.summary}]' "$response_file"
