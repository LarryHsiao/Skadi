#!/bin/bash
# Usage: working-jira-ticket.sh <ISSUE-KEY>
# Prints JSON: {summary, status, type, priority, description}
#   summary, status, type, priority — plain strings ("" when absent)
#   description — ADF flattened to plain markdown-ish text ("" when absent)
# Resolves Jira creds via secret.sh (vault first, env fallback).
# Uses Jira REST v3. On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
if [[ -z "$ISSUE_KEY" ]]; then
  echo '{"error":"usage: working-jira-ticket.sh <ISSUE-KEY>"}'
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
trap 'rm -f "$issue_file"' EXIT

status=$(curl -sS -o "$issue_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY?fields=summary,status,description,priority,issuetype")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$issue_file" \
    '{error: ("fetch issue failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

python - "$issue_file" <<'PY'
import json, sys
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

issue = json.load(open(sys.argv[1], "r", encoding="utf-8"))
f = issue.get("fields") or {}
out = {
    "summary":     f.get("summary") or "",
    "status":      ((f.get("status") or {}).get("name") or ""),
    "type":        ((f.get("issuetype") or {}).get("name") or ""),
    "priority":    ((f.get("priority") or {}).get("name") or ""),
    "description": adf_to_text(f.get("description")),
}
print(json.dumps(out, ensure_ascii=False))
PY
