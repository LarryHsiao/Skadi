#!/bin/bash
# Usage: jira-daily.sh <jql>
# Fetches Jira issues and prints ISSUE|status|bar|key|summary lines

JQL="$1"

# Resolution order for url/email: vault -> memory -> env -> default.
# Vault-only first (sentinel "-" disables env fallback so memory can still win).
SECRET="$(dirname "$0")/secret.sh"
JIRA_BASE_URL_VAULT="$("$SECRET" jira uri - 2>/dev/null || true)"
JIRA_EMAIL_VAULT="$("$SECRET" jira username - 2>/dev/null || true)"

# Flat-file fallback (offline/legacy use), NOT auto-memory: auto-memory is
# scoped per project directory and would be invisible when this hook runs
# from a repo other than skadi. Same reasoning as protected_repos.md /
# mend_repos.md / repo-watch/repos.md.
CONFIG_FILE="$HOME/.skadi/jira/config.md"
JIRA_BASE_URL_MEM=""
JIRA_EMAIL_MEM=""
if [[ -f "$CONFIG_FILE" ]]; then
  JIRA_BASE_URL_MEM=$(awk -F'`' '/JIRA_BASE_URL/{v=$3; sub(/^: */,"",v); print v; exit}' "$CONFIG_FILE")
  JIRA_EMAIL_MEM=$(awk -F'`' '/JIRA_EMAIL/{v=$3; sub(/^: */,"",v); print v; exit}' "$CONFIG_FILE")
fi

JIRA_BASE_URL="${JIRA_BASE_URL_VAULT:-${JIRA_BASE_URL_MEM:-${JIRA_BASE_URL:-https://jubo.atlassian.net}}}"
JIRA_EMAIL="${JIRA_EMAIL_VAULT:-${JIRA_EMAIL_MEM:-${JIRA_EMAIL:-larryhsiao@jubo.health}}}"

JIRA_API_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

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
