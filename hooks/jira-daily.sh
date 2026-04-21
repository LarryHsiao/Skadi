#!/bin/bash
# Usage: jira-daily.sh <jql>
# Fetches Jira issues and prints ISSUE|status|bar|key|summary lines

JQL="$1"

# Prefer memory over env — env can be polluted by unrelated JIRA_BASE_URL/JIRA_EMAIL
CONFIG_FILE="$HOME/.claude-personal/projects/$(pwd | sed 's|/|-|g')/memory/jira_config.md"
if [[ -f "$CONFIG_FILE" ]]; then
  mem_url=$(awk -F'`' '/JIRA_BASE_URL/{print $4; exit}' "$CONFIG_FILE")
  mem_email=$(awk -F'`' '/JIRA_EMAIL/{print $4; exit}' "$CONFIG_FILE")
  [[ -n "$mem_url" ]]   && JIRA_BASE_URL="$mem_url"
  [[ -n "$mem_email" ]] && JIRA_EMAIL="$mem_email"
fi

JIRA_BASE_URL="${JIRA_BASE_URL:-https://jubo.atlassian.net}"
JIRA_EMAIL="${JIRA_EMAIL:-larryhsiao@jubo.health}"

curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" \
  --get \
  --data-urlencode "jql=$JQL" \
  --data-urlencode "fields=summary,status,priority" \
  --data-urlencode "maxResults=50" \
  | python3 -c "
import sys, json

d = json.load(sys.stdin)

if d.get('errorMessages') or d.get('errors'):
    msgs = d.get('errorMessages', []) + list(d.get('errors', {}).values())
    print('API_ERROR|' + '; '.join(msgs))
    sys.exit(0)

issues = d.get('issues', [])
if not issues:
    print('EMPTY')
    sys.exit(0)

PRIORITY_BARS = {
    'Highest': '|||',
    'High':    '|||',
    'Medium':  '|| ',
    'Low':     '|  ',
    'Lowest':  '|  ',
}

for issue in issues:
    f = issue['fields']
    status_name = f['status']['name']
    priority_name = f['priority']['name'] if f.get('priority') else 'Medium'
    bar = PRIORITY_BARS.get(priority_name, '|| ')
    summary = f['summary'][:55]
    print(f'ISSUE|{status_name}|{bar}|{issue[\"key\"]}|{summary}')
"
