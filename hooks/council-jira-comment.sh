#!/bin/bash
# Usage: echo "body text" | council-jira-comment.sh <ISSUE-KEY>
# Posts the comment body (read from stdin) on the Jira issue.
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3 with ADF body. Markdown-like bodies are converted naively:
# paragraphs split by blank lines, single newlines become hardBreaks. Bracket
# tokens (e.g. [PLAN vN]) survive intact.
#
# On success, prints: posted: id=<id> created=<epoch-ms> url=<issue-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Env: COUNCIL_DRY_RUN=1 prints the would-be ADF payload to stdout instead
# of posting. Use this for shape verification without writing to Jira.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
if [[ -z "$ISSUE_KEY" ]]; then
  echo '{"error":"issue key required"}'
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
import json, sys
sys.stdout.reconfigure(encoding="utf-8")

text = open(sys.argv[1], "r", encoding="utf-8").read().rstrip("\n")
paragraphs = text.split("\n\n")

content = []
for para in paragraphs:
    if not para.strip():
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
  echo "DRY-RUN payload for $ISSUE_KEY:"
  cat "$payload_file"
  exit 0
fi

status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload_file" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/comment")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("post comment failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

python - "$response_file" "$URL" "$ISSUE_KEY" <<'PY'
import json, sys
sys.stdout.reconfigure(encoding="utf-8")
from datetime import datetime

resp = json.load(open(sys.argv[1], "r", encoding="utf-8"))
url, key = sys.argv[2].rstrip("/"), sys.argv[3]

cid = resp.get("id", "?")
created = resp.get("created", "")
ts = 0
if created:
    s = created.replace("Z", "+00:00")
    if len(s) >= 5 and s[-5] in "+-" and s[-3] != ":":
        s = s[:-2] + ":" + s[-2:]
    try:
        ts = int(datetime.fromisoformat(s).timestamp() * 1000)
    except Exception:
        pass

print(f"posted: id={cid} created={ts} url={url}/browse/{key}")
PY
