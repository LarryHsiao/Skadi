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

if ! fetch_to_file "issue" "/rest/api/3/issue/$ISSUE_KEY?fields=summary,description" "$issue_file"; then
  exit 1
fi
if ! fetch_to_file "comments" "/rest/api/3/issue/$ISSUE_KEY/comment?maxResults=200" "$comments_file"; then
  exit 1
fi

python - "$issue_file" "$comments_file" <<'PY'
import json, sys
from datetime import datetime
sys.stdout.reconfigure(encoding="utf-8")

def walk(node, out):
    if isinstance(node, list):
        for x in node:
            walk(x, out)
        return
    if not isinstance(node, dict):
        return
    t = node.get("type")
    if t == "text":
        out.append(node.get("text", ""))
    elif t == "hardBreak":
        out.append("\n")
    elif t == "paragraph":
        walk(node.get("content", []), out)
        out.append("\n\n")
    elif t == "heading":
        lvl = (node.get("attrs") or {}).get("level", 1)
        out.append("#" * lvl + " ")
        walk(node.get("content", []), out)
        out.append("\n\n")
    elif t == "bulletList":
        for item in node.get("content", []):
            out.append("- ")
            walk(item.get("content", []), out)
            if not out or not out[-1].endswith("\n"):
                out.append("\n")
        out.append("\n")
    elif t == "orderedList":
        for i, item in enumerate(node.get("content", []), 1):
            out.append(f"{i}. ")
            walk(item.get("content", []), out)
            if not out or not out[-1].endswith("\n"):
                out.append("\n")
        out.append("\n")
    elif t == "codeBlock":
        out.append("```\n")
        walk(node.get("content", []), out)
        out.append("\n```\n\n")
    elif t == "rule":
        out.append("\n---\n\n")
    elif t == "blockquote":
        out.append("> ")
        walk(node.get("content", []), out)
        out.append("\n\n")
    else:
        walk(node.get("content", []), out)

def adf_to_text(adf):
    if adf is None:
        return ""
    if isinstance(adf, str):
        return adf
    parts = []
    walk(adf, parts)
    return "".join(parts).strip()

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
print(json.dumps(out, ensure_ascii=False))
PY
