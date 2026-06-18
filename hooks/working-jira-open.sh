#!/bin/bash
# Usage: working-jira-open.sh <PROJECT-KEY> [MAX]
# Lists the project's open tickets (statusCategory To Do or In Progress),
# most-recently-updated first, for the /working ticket picker.
#   MAX — cap on rows returned (default 20)
# Prints JSON array: [{"key":"ELROND-148","status":"To Do","summary":"..."}]
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3. On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

PROJECT_KEY="${1:-}"
MAX="${2:-20}"

if [[ -z "$PROJECT_KEY" ]]; then
  echo '{"error":"usage: working-jira-open.sh <PROJECT-KEY> [MAX]"}'
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
jql="project = $PROJECT_KEY AND statusCategory in (\"To Do\",\"In Progress\") ORDER BY updated DESC"

page_file=$(mktemp)
trap 'rm -f "$page_file"' EXIT

status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  --data-urlencode "jql=$jql" \
  --data-urlencode "fields=summary,status" \
  --data-urlencode "maxResults=$MAX" \
  "$URL/rest/api/3/search/jql")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg j "$jql" --rawfile b "$page_file" \
    '{error: ("jira open-list failed (http=" + $s + ")"), jql: $j, response: $b}'
  exit 1
fi

jq -c '[(.issues // [])[] | {key: .key, status: (.fields.status.name // ""), summary: (.fields.summary // "")}]' "$page_file"
