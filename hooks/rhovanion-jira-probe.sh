#!/bin/bash
# Usage: rhovanion-jira-probe.sh <PROJECT-KEY> <FILTER> [CURSOR-MS]
# Cheap movement probe for one Jira project: counts in-scope issues whose
# `updated` timestamp is newer than CURSOR-MS. This is Rhovanion's gate — it
# rides /anduin for a project only when this prints a count > 0.
#   FILTER (required): saved-filter ID (all digits, e.g. "10363") or a raw JQL
#     fragment — resolved exactly as the glorfindel-jira-list hook resolves it.
#   CURSOR-MS (optional): epoch milliseconds of the project's last ride. Absent
#     or "0" means cold start — every in-scope issue counts as moved.
# Prints a single integer (issues updated since the cursor, capped at one page).
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# JQL's `updated >` carries minute precision and is evaluated in the token
# owner's timezone; the cursor is formatted in local machine time. A sub-minute
# or timezone skew can at worst trigger one extra ride — never a missed one.

set -euo pipefail
export LC_ALL=C.UTF-8

PAGE_SIZE=50

PROJECT_KEY="${1:-}"
FILTER="${2:-}"
CURSOR_MS="${3:-0}"
[[ -z "$CURSOR_MS" ]] && CURSOR_MS=0

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

cursor_sec=$((CURSOR_MS / 1000))
# GNU date wants `-d @epoch`; BSD/macOS date wants `-r epoch`. Try GNU first.
cursor_ts=$(date -d "@$cursor_sec" "+%Y/%m/%d %H:%M" 2>/dev/null \
  || date -r "$cursor_sec" "+%Y/%m/%d %H:%M")

if [[ "$FILTER" =~ ^[0-9]+$ ]]; then
  jql="filter = $FILTER AND updated > \"$cursor_ts\" ORDER BY updated DESC"
else
  jql="project = $PROJECT_KEY AND ($FILTER) AND updated > \"$cursor_ts\" ORDER BY updated DESC"
fi

page_file=$(mktemp)
trap 'rm -f "$page_file"' EXIT

status=$(curl -sS -G -o "$page_file" -w "%{http_code}" \
  -u "$EMAIL:$TOK" \
  -H "Accept: application/json" \
  --data-urlencode "jql=$jql" \
  --data-urlencode "fields=updated" \
  --data-urlencode "maxResults=$PAGE_SIZE" \
  "$URL/rest/api/3/search/jql")

if [[ "$status" != 2* ]]; then
  jq -cn --arg s "$status" --arg j "$jql" --rawfile b "$page_file" \
    '{error: ("jira probe failed (http=" + $s + ")"), jql: $j, response: $b}'
  exit 1
fi

# A 200 with no `.issues` key is a malformed response, not "zero moved" —
# surface it loudly rather than letting `null | length` read as a silent 0.
if [[ "$(jq -r 'has("issues")' "$page_file")" != "true" ]]; then
  jq -cn --arg j "$jql" --rawfile b "$page_file" \
    '{error: "jira probe: response carried no .issues key", jql: $j, response: $b}'
  exit 1
fi

jq '.issues | length' "$page_file"
