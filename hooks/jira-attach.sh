#!/bin/bash
# Usage: jira-attach.sh <ISSUE-KEY> <FILE-PATH>
# Attaches FILE to the issue, replacing any existing attachment of the same name
# (so a re-rendered diagram PNG does not stack). Resolves creds via secret.sh.
# On success, prints: attached: name=<filename> id=<attachment-id> url=<issue-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Env: COUNCIL_DRY_RUN=1 skips the delete+upload and prints
# "DRY-RUN would attach <filename> to <ISSUE-KEY>" instead. Use this for shape
# verification without writing to Jira — Jira tickets are real work.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
FILE_PATH="${2:-}"
if [[ -z "$ISSUE_KEY" || -z "$FILE_PATH" ]]; then
  echo '{"error":"usage: jira-attach.sh <ISSUE-KEY> <FILE-PATH>"}'
  exit 1
fi
if [[ ! -f "$FILE_PATH" ]]; then
  echo "{\"error\":\"file not found: $FILE_PATH\"}"
  exit 1
fi

NAME="$(basename "$FILE_PATH")"

SECRET="$(dirname "$0")/secret.sh"
JIRA_URL="$("$SECRET" jira uri JIRA_BASE_URL 2>/dev/null || true)"
JIRA_EMAIL="$("$SECRET" jira username JIRA_EMAIL 2>/dev/null || true)"
JIRA_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_TOKEN" ]]; then
  echo '{"error":"jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)"}'
  exit 1
fi

URL="${JIRA_URL%/}"

if [[ "${COUNCIL_DRY_RUN:-0}" == "1" ]]; then
  echo "DRY-RUN would attach $NAME to $ISSUE_KEY"
  exit 0
fi

list_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$list_file" "$response_file"' EXIT

# 1. Find and delete any prior attachment of the same name (replace-in-place).
status=$(curl -sS -o "$list_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY?fields=attachment")
if [[ "$status" == 2* ]]; then
  while IFS= read -r old_id; do
    [[ -n "$old_id" ]] && curl -sS -o /dev/null -X DELETE \
      -u "$JIRA_EMAIL:$JIRA_TOKEN" \
      "$URL/rest/api/3/attachment/$old_id" || true
  done < <(jq -r --arg n "$NAME" '.fields.attachment[]? | select(.filename == $n) | .id' "$list_file")
fi

# 2. Upload the new file (multipart).
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "X-Atlassian-Token: no-check" \
  -H "Accept: application/json" \
  -F "file=@$FILE_PATH;type=image/png" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/attachments")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("attach failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

att_id=$(jq -r '.[0].id // ""' "$response_file")
printf 'attached: name=%s id=%s url=%s/browse/%s\n' "$NAME" "$att_id" "$URL" "$ISSUE_KEY"
