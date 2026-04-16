---
name: daily
description: Use when the user runs /daily [...args]. Shows Jira tasks assigned to a user, grouped by status and sorted by priority. Args: optional project keys and optional @person. Example: /daily, /daily PROJ, /daily PROJ1 PROJ2, /daily @david, /daily PROJ @david.
---

# Daily Tasks Report

Shows Jira tasks assigned to you or someone else, grouped into three categories (In Progress, To Do, Done) and sorted by priority.

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

### 3. Load status mapping from memory

Check memory file `jira_status_mapping.md` for a JSON mapping of Jira status names to categories.

Format in memory:
```json
{
  "Open": "todo",
  "In Progress": "in_progress",
  "Done": "done",
  "Closed": "done"
}
```

Valid categories: `todo`, `in_progress`, `in_review`, `done`.

If the file doesn't exist yet, that's fine — it will be created after the first run when unmapped statuses are encountered (step 6).

### 4. Resolve assignee

- `@person` was provided → use the name as the assignee display name in JQL: `assignee = "PERSON"`
- No `@person` → use `JIRA_EMAIL` from memory: `assignee = "JIRA_EMAIL"`

Determine the label for the header:
- Using `JIRA_EMAIL` → `"My Tasks"`
- Using a display name → `"PERSON's Tasks"` (capitalize first letter)

### 5. Fetch tasks from Jira

Check memory file `jira_filter.md` for a saved filter ID. If found, use it as the base scope.

Build the JQL:
- If a saved filter exists: start with `filter = FILTER_ID AND ...`
- If no saved filter: use `project = KEY` (or `project IN (KEY1, KEY2)` for multiple keys)

Then append `assignee = "ASSIGNEE"` and any project filter if using a saved filter with explicit project args.

**No `statusCategory` filter** — fetch all statuses so we can categorize them ourselves.

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

for issue in issues:
    f = issue['fields']
    status_name = f['status']['name']
    priority_name = f['priority']['name'] if f.get('priority') else 'Medium'
    bar = PRIORITY_BARS.get(priority_name, '|| ')
    summary = f['summary'][:55]
    print(f'ISSUE|{status_name}|{bar}|{issue[\"key\"]}|{summary}')
"
```

**Constructed JQL (with saved filter):**

```
filter = 10363 AND assignee = "ASSIGNEE"
  ORDER BY priority ASC
```

**Constructed JQL (without saved filter):**

```
project IN (KEY1, KEY2) AND assignee = "ASSIGNEE"
  ORDER BY priority ASC
```

### 6. Map statuses to categories

After fetching, collect all unique status names from the `ISSUE|` lines.

Compare against the mapping loaded in step 3. For any **unmapped** status name:

1. Use AskUserQuestion to ask the user which category it belongs to:
   > Status `"Review"` isn't mapped yet. Which category?
   > 1. Todo
   > 2. In Progress
   > 3. Done
2. Add the mapping to the in-memory map
3. After all unmapped statuses are resolved, **update** `jira_status_mapping.md` with the full JSON mapping

If all statuses are already mapped, skip this step silently.

### 7. Render output

Group the issues by their mapped category (`in_progress`, `todo`, `done`) and render.

**Header:**
```
PROJ — My Tasks (5)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

- Project part: single key = `PROJ`, multiple = `PROJ1, PROJ2`
- Label: `My Tasks` or `David's Tasks`
- Count: total issue count in parentheses

**Body — grouped by category, in this order: In Progress → In Review → To Do → Done:**
```
In Progress
  ▶ [|||] PROJ-456  Add user dashboard
  ▶ [|| ] PROJ-198  Refactor notification service
In Review
  ◆ [|||] PROJ-321  Implement search API
  ◆ [|| ] PROJ-654  Update auth flow
To Do
  ○ [|||] PROJ-201  Implement patient alert system
  ○ [|| ] PROJ-789  Implement CSV export
  ○ [|  ] PROJ-210  Update onboarding copy
Done
  ✓ [|||] PROJ-300  Set up CI pipeline
  ✓ [|| ] PROJ-112  Fix login redirect
```

- Each issue: `  SYMBOL [BAR] KEY  SUMMARY`
- `▶` for In Progress, `◆` for In Review, `○` for To Do, `✓` for Done
- Bar: `[|||]` Highest/High · `[|| ]` Medium · `[|  ]` Low/Lowest
- Key column width: pad to align summaries (use the longest key in the result)
- Summary truncated to 55 chars
- **Omit empty categories** — if a category has no issues, don't show the heading

**Footer:**
```
───────────────────────────────────────────
  N in progress · N in review · N to do · N done
```

**Special cases:**

If `EMPTY`:
```
PROJ — My Tasks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
No tasks assigned.
```

If `API_ERROR`:
> Jira API error: [message]. Check your project key and `JIRA_API_TOKEN`.

## Rules

- Never ask the user to confirm the project key if it was found in git history or provided as an argument
- Always check memory before asking the user for config values
- If `JIRA_API_TOKEN` is missing, stop and tell the user — do not proceed
- Default to current user's tasks when no `@person` is given
- Summaries truncated to 55 chars in output
- Only ask about unmapped statuses once — save to `jira_status_mapping.md` immediately
- Omit empty categories from output (e.g. if no Done tasks, skip that section)
- When asking about unmapped statuses, batch them into a single question if multiple are unknown
