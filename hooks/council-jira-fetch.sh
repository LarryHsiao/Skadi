#!/bin/bash
# Usage: council-jira-fetch.sh <ISSUE-KEY>
# Prints JSON: {summary, description, comments:[{author,login,text,created}]}
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3 (the v2 search API has been removed by Atlassian).
# ADF descriptions/comments are flattened to plain text via Python.
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

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

issue_file=$(mktemp)
comments_file=$(mktemp)
trap 'rm -f "$issue_file" "$comments_file"' EXIT

fetch_to_file() {
  local label="$1" path="$2" out="$3"
  local status
  status=$(curl -sS -o "$out" -w "%{http_code}" \
    -u "$JIRA_EMAIL:$JIRA_TOKEN" \
    -H "Accept: application/json" \
    "$URL$path")
  if [[ "$status" != 2* ]]; then
    jq -cn --arg label "$label" --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$out" \
      '{error: ("fetch " + $label + " failed for " + $id + " (http=" + $s + ")"), response: $b}'
    return 1
  fi
}

if ! fetch_to_file "issue" "/rest/api/3/issue/$ISSUE_KEY?fields=summary,description,parent" "$issue_file"; then
  exit 1
fi
if ! fetch_to_file "comments" "/rest/api/3/issue/$ISSUE_KEY/comment?maxResults=200" "$comments_file"; then
  exit 1
fi

parent_file=$(mktemp)
trap 'rm -f "$issue_file" "$comments_file" "$parent_file"' EXIT
PARENT_KEY=$(jq -r '.fields.parent.key // empty' "$issue_file")
if [[ -n "$PARENT_KEY" ]]; then
  if ! fetch_to_file "parent" "/rest/api/3/issue/$PARENT_KEY?fields=summary,description" "$parent_file"; then
    exit 1
  fi
fi

PYTHONPATH="$(dirname "$0")" python - "$issue_file" "$comments_file" "$parent_file" <<'PY'
import json, sys
from datetime import datetime
sys.stdout.reconfigure(encoding="utf-8")
from jira_adf import adf_to_text

def parse_jira_ts(s):
    if not s:
        return 0
    s = s.replace("Z", "+00:00")
    if len(s) >= 5 and s[-5] in "+-" and s[-3] != ":":
        s = s[:-2] + ":" + s[-2:]
    try:
        return int(datetime.fromisoformat(s).timestamp() * 1000)
    except Exception:
        return 0

issue = json.load(open(sys.argv[1], "r", encoding="utf-8"))
comments_doc = json.load(open(sys.argv[2], "r", encoding="utf-8"))

fields = issue.get("fields") or {}
out = {
    "summary": fields.get("summary") or "",
    "description": adf_to_text(fields.get("description")),
    "comments": [
        {
            "id":     c.get("id") or "",
            "author": ((c.get("author") or {}).get("displayName") or ""),
            "login":  ((c.get("author") or {}).get("emailAddress") or
                       (c.get("author") or {}).get("accountId") or ""),
            "text":   adf_to_text(c.get("body")),
            "created": parse_jira_ts(c.get("created")),
        }
        for c in (comments_doc.get("comments") or [])
    ],
}
parent_path = sys.argv[3] if len(sys.argv) > 3 else ""
parent = None
if parent_path:
    try:
        pj = json.load(open(parent_path, "r", encoding="utf-8"))
        pf = pj.get("fields") or {}
        if pj.get("key"):
            parent = {"id": pj["key"],
                      "summary": pf.get("summary") or "",
                      "description": adf_to_text(pf.get("description"))}
    except Exception:
        parent = None
out["parent"] = parent
print(json.dumps(out, ensure_ascii=False))
PY
