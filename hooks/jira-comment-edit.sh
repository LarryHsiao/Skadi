#!/bin/bash
# Usage: echo "new body" | jira-comment-edit.sh <ISSUE-KEY> <COMMENT-ID>
# Replaces the body of an existing Jira comment in place (modify, not append).
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3 PUT with ADF body. Markdown-like bodies are converted naively,
# mirroring council-jira-comment.sh: paragraphs split by blank lines, single
# newlines become hardBreaks. Bracket tokens (e.g. [COUNSEL vN]) survive intact.
#
# On success, prints: edited: id=<comment-id> url=<issue-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Env: COUNCIL_DRY_RUN=1 prints the would-be ADF payload to stdout instead
# of editing. Use this for shape verification without writing to Jira.
# Env: JIRA_ATTACHMENT_ID, if set, turns a body paragraph reading exactly
# "[[PLAN-PREVIEW]]" into a plain-text pointer at the ticket's attachment
# instead of emitting the sentinel as literal text. (An earlier version tried
# an ADF mediaSingle inline embed; Jira Cloud rejected it with
# ATTACHMENT_VALIDATION_ERROR on a real ticket, so this points at the
# Attachments panel instead of embedding inline.)

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
COMMENT_ID="${2:-}"
if [[ -z "$ISSUE_KEY" || -z "$COMMENT_ID" ]]; then
  echo '{"error":"usage: jira-comment-edit.sh <ISSUE-KEY> <COMMENT-ID>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
JIRA_URL="$("$SECRET" jira uri JIRA_BASE_URL 2>/dev/null || true)"
JIRA_EMAIL="$("$SECRET" jira username JIRA_EMAIL 2>/dev/null || true)"
JIRA_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_TOKEN" ]]; then
  echo '{"error":"jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)"}'
  exit 1
fi

URL="${JIRA_URL%/}"

body_raw=$(cat)
if [[ -z "$body_raw" ]]; then
  echo '{"error":"empty comment body on stdin"}'
  exit 1
fi

body_file=$(mktemp)
payload_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$body_file" "$payload_file" "$response_file"' EXIT

printf '%s' "$body_raw" > "$body_file"

if ! iconv -f UTF-8 -t UTF-8 "$body_file" >/dev/null 2>&1; then
  if iconv -f WINDOWS-1252 -t UTF-8 "$body_file" > "$body_file.utf8" 2>/dev/null; then
    mv "$body_file.utf8" "$body_file"
  else
    echo '{"error":"comment body is neither valid UTF-8 nor CP1252"}'
    exit 1
  fi
fi

python - "$body_file" > "$payload_file" <<'PY'
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")

text = open(sys.argv[1], "r", encoding="utf-8").read().rstrip("\n")
paragraphs = text.split("\n\n")
attachment_id = os.environ.get("JIRA_ATTACHMENT_ID", "")

content = []
for para in paragraphs:
    if not para.strip():
        continue
    if para.strip() == "[[PLAN-PREVIEW]]" and attachment_id:
        content.append({
            "type": "paragraph",
            "content": [{"type": "text", "text": "\U0001F4CE Diagram attached to this issue — see Attachments below."}],
        })
        continue
    lines = para.split("\n")
    nodes = []
    for i, line in enumerate(lines):
        if i > 0:
            nodes.append({"type": "hardBreak"})
        if line:
            nodes.append({"type": "text", "text": line})
    if nodes:
        content.append({"type": "paragraph", "content": nodes})

if not content:
    content = [{"type": "paragraph", "content": [{"type": "text", "text": text or " "}]}]

payload = {"body": {"version": 1, "type": "doc", "content": content}}
print(json.dumps(payload, ensure_ascii=False))
PY

if [[ "${COUNCIL_DRY_RUN:-0}" == "1" ]]; then
  echo "DRY-RUN payload for $ISSUE_KEY comment $COMMENT_ID:"
  cat "$payload_file"
  exit 0
fi

status=$(curl -sS -X PUT -o "$response_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload_file" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/comment/$COMMENT_ID")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$COMMENT_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("edit comment failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

printf 'edited: id=%s url=%s/browse/%s\n' "$COMMENT_ID" "$URL" "$ISSUE_KEY"
