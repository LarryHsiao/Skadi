---
name: daily
description: Use when the user runs /daily [...args]. Shows Jira tasks assigned to a user, grouped by status and sorted by priority. Args: optional project keys and optional @person. Example: /daily, /daily PROJ, /daily PROJ1 PROJ2, /daily @david, /daily PROJ @david.
---

# Daily Tasks Report

Shows open Jira tasks (In Progress + To Do) assigned to you or someone else, grouped by status and sorted by priority.

## Argument Parsing

Arguments: `/daily [project...] [@person]`

- Words matching `[A-Z]+-?` (all uppercase, no digits) → project keys
- Words starting with `@` → person filter (strip the `@`)
- No `@person` → default to current user (use `JIRA_EMAIL` from memory)
- No project keys → auto-detect from git or memory

Examples:
- `/daily` → my tasks, auto-detect project
- `/daily PROJ` → my tasks in PROJ
- `/daily PROJ1 PROJ2` → my tasks across PROJ1 and PROJ2
- `/daily @david` → david's tasks, auto-detect project
- `/daily PROJ @david` → david's tasks in PROJ

---

## Workflow

### 1. Load Jira config from memory

Check memory file `jira_config.md` for:
- `JIRA_BASE_URL` — e.g. `https://company.atlassian.net`
- `JIRA_EMAIL` — e.g. `user@example.com`

If not found, ask the user for both values via AskUserQuestion, then save to memory.

Require `JIRA_API_TOKEN` env var. If not set, tell the user:
> Set `JIRA_API_TOKEN` in your environment (e.g. in `~/.zshrc`) with an Atlassian API token from https://id.atlassian.com/manage-profile/security/api-tokens

### 2. Resolve project key(s)

If project keys were provided as arguments, use them directly — do NOT ask the user to confirm.

Otherwise, auto-detect:

```bash
# Try git log first
git log --oneline -100 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | grep -oE '^[A-Z]+' | head -1

# Fall back to branch names
git branch -a 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | grep -oE '^[A-Z]+' | head -1
```

If still not found, check memory file `jira_project.md`. If not there either, ask the user.

### 3. Resolve assignee

- `@person` was provided → use the name as the assignee display name in JQL: `assignee = "PERSON"`
- No `@person` → use `JIRA_EMAIL` from memory: `assignee = "JIRA_EMAIL"`

Determine the label for the header:
- Using `JIRA_EMAIL` → `"My Tasks"`
- Using a display name → `"PERSON's Tasks"` (capitalize first letter)

### 4. Fetch tasks from Jira

Build the JQL. For multiple project keys use `project IN (KEY1, KEY2)`, for a single key use `project = KEY`.

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" \
  --get \
  --data-urlencode "jql=CONSTRUCTED_JQL" \
  --data-urlencode "fields=summary,status,priority" \
  --data-urlencode "maxResults=50" \
  | python3 -c "
import sys, json
from collections import defaultdict

d = json.load(sys.stdin)

# Check for API errors
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
PRIORITY_ORDER = {'Highest': 0, 'High': 1, 'Medium': 2, 'Low': 3, 'Lowest': 4}
CATEGORY_ORDER = {'In Progress': 0, 'To Do': 1}

groups = defaultdict(list)
for issue in issues:
    f = issue['fields']
    cat = f['status']['statusCategory']['name']
    priority_name = f['priority']['name'] if f.get('priority') else 'Medium'
    priority_order = PRIORITY_ORDER.get(priority_name, 2)
    bar = PRIORITY_BARS.get(priority_name, '|| ')
    summary = f['summary'][:55]
    groups[cat].append({
        'key': issue['key'],
        'summary': summary,
        'bar': bar,
        'priority_order': priority_order,
        'cat': cat,
    })

total = sum(len(v) for v in groups.values())
print(f'TOTAL|{total}')

for cat in sorted(groups.keys(), key=lambda c: CATEGORY_ORDER.get(c, 9)):
    items = sorted(groups[cat], key=lambda x: x['priority_order'])
    print(f'GROUP|{cat}|{len(items)}')
    for item in items:
        symbol = '▶' if cat == 'In Progress' else '○'
        print(f'ISSUE|{symbol}|{item[\"bar\"]}|{item[\"key\"]}|{item[\"summary\"]}')
"
```

**Constructed JQL:**

```
project IN (KEY1, KEY2) AND assignee = "ASSIGNEE"
  AND statusCategory IN ("In Progress", "To Do")
  ORDER BY statusCategory DESC, priority ASC
```

### 5. Render output

Claude renders the output from the parsed lines above.

**Header:**
```
PROJ — My Tasks (5)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

- Project part: single key = `PROJ`, multiple = `PROJ1, PROJ2`
- Label: `My Tasks` or `David's Tasks`
- Count: total issue count in parentheses

**Body — grouped by status:**
```
In Progress
  ▶ [|||] PROJ-456  Add user dashboard
  ▶ [|| ] PROJ-198  Refactor notification service
To Do
  ○ [|||] PROJ-201  Implement patient alert system
  ○ [|| ] PROJ-789  Implement CSV export
  ○ [|  ] PROJ-210  Update onboarding copy
```

- Each issue: `  SYMBOL [BAR] KEY  SUMMARY`
- `▶` for In Progress, `○` for To Do
- Bar: `[|||]` Highest/High · `[|| ]` Medium · `[|  ]` Low/Lowest
- Key column width: pad to align summaries (use the longest key in the result)
- Summary truncated to 55 chars

**Footer:**
```
───────────────────────────────────────────
  N in progress · N to do
```

**Special cases:**

If `EMPTY`:
```
PROJ — My Tasks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
No open tasks assigned.
```

If `API_ERROR`:
> Jira API error: [message]. Check your project key and `JIRA_API_TOKEN`.

## Rules

- Never ask the user to confirm the project key if it was found in git history or provided as an argument
- Always check memory before asking the user for config values
- If `JIRA_API_TOKEN` is missing, stop and tell the user — do not proceed
- Default to current user's tasks when no `@person` is given
- Summaries truncated to 55 chars in output
