---
name: jira
description: Use when the user runs /jira [verb] [...args]. Supported verbs: create, status. Example: /jira create, /jira create bug, /jira status, /jira status me, /jira status --filter 10363.
---

# Jira Skill

Dispatches to a Jira action based on the verb argument.

## Argument Parsing

Arguments: `/jira [verb] [...rest]`

- `verb`: the action to perform. Supported values: `create`, `status`
- If no verb is provided or the verb is unrecognized, tell the user the supported verbs and stop.

---

## Verb: create

Creates a Jira issue for the current project, auto-detecting the project key from git history.

Arguments after `create`: `/jira create [type] [title]`

### 1. Load Jira config from memory

Check memory file `jira_config.md` for:
- `JIRA_BASE_URL` — e.g. `https://company.atlassian.net`
- `JIRA_EMAIL` — e.g. `user@example.com`

If not found, ask the user for both values via AskUserQuestion, then save to memory:
- Write `jira_config.md` to the current project's auto-memory directory (the `memory/` path named in the system prompt)
- Add pointer to `MEMORY.md`

Require `JIRA_API_TOKEN` env var. If not set, tell the user:
> Set `JIRA_API_TOKEN` in your environment (e.g. in `~/.zshrc`) with an Atlassian API token from https://id.atlassian.com/manage-profile/security/api-tokens

### 2. Parse arguments

- `type`: `task`, `bug`, or `epic` — default to `task` if not provided or not one of those values
- `title`: everything after the type (if the second word is not a valid type, treat the entire argument as the title with type defaulting to `task`)
- Map type to Jira issue type names: `task` → `Task`, `bug` → `Bug`, `epic` → `Epic`

### 3. Auto-detect Jira project key

Search git history and branches for Jira ticket patterns (`[A-Z]+-[0-9]+`):

```bash
# Try git log first
git log --oneline -100 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1

# Fall back to branch names
git branch -a 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
```

Extract the project key (e.g. `PROJ` from `PROJ-123`) and use it silently — do NOT ask the user to confirm.

If no ticket is found anywhere:
- Check memory file `jira_project.md` for a saved project key
- If still not found, ask the user for the project key, then save to memory:
  - Write `jira_project.md` to the current project's auto-memory directory (the `memory/` path named in the system prompt)
  - Add pointer to `MEMORY.md`

### 4. Get issue summary

If a title was provided as an argument, use it directly — do NOT ask the user.

Otherwise, use AskUserQuestion to get the issue title/summary. Keep it concise.

### 5. Fetch sprints and ask user to pick

**a. Get the board ID for the project:**

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/agile/1.0/board?projectKeyOrId=PROJECT_KEY" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['values'][0]['id']) if d.get('values') else print('')"
```

If no board is found, skip sprint selection entirely.

**b. Get active and future sprints:**

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/agile/1.0/board/BOARD_ID/sprint?state=active,future" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('values', []):
    print(s['id'], s['name'], s.get('state',''))
"
```

**c. Present sprint options via AskUserQuestion:**

List each sprint as an option (name + state), plus a "No sprint (backlog)" option.

If the user picks a sprint, record the sprint ID for the issue creation payload.

### 6. Create the issue

Build the payload and POST to Jira:

```bash
python3 -c "
import json, subprocess, os, sys

payload = {
    'fields': {
        'project': {'key': 'PROJECT_KEY'},
        'summary': 'SUMMARY',
        'issuetype': {'name': 'ISSUE_TYPE'}
    }
}

# Add sprint if selected (classic boards use customfield_10020)
# payload['fields']['customfield_10020'] = SPRINT_ID

data = json.dumps(payload)
result = subprocess.run([
    'curl', '-s', '-X', 'POST',
    '-u', f\"{os.environ['JIRA_EMAIL']}:{os.environ['JIRA_API_TOKEN']}\",
    '-H', 'Content-Type: application/json',
    '-d', data,
    f\"{os.environ['JIRA_BASE_URL']}/rest/api/3/issue\"
], capture_output=True, text=True)
print(result.stdout)
"
```

Use the sprint field `customfield_10020` (integer sprint ID) for classic Jira boards. If it returns a field error for that field, retry without the sprint field and note that the user should assign the sprint manually.

For next-gen (team-managed) projects, sprint assignment is done via the agile API after creation:

```bash
curl -s -X POST -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/agile/1.0/sprint/SPRINT_ID/issue" \
  -d '{"issues": ["ISSUE_KEY"]}'
```

### 7. Report the result

Parse the response and show:
```
Created: PROJECT-123
URL: https://company.atlassian.net/browse/PROJECT-123
```

Then ask via AskUserQuestion: "Start working on PROJECT-123 now?" (yes → chain to `/working PROJECT-123`).

---

## Verb: status

Shows a sprint board overview grouped by status, sorted by priority. Acts as a secretary: tells you what the team is doing and what you should focus on next.

Sibling: `/daily` follows one person's assigned tasks, across projects if several are named; `/jira status` renders the whole board of the current sprint.

Arguments after `status`: `/jira status [filter] [--filter <id>] [--all]`

- No argument: show all issues in the current sprint
- `me`: show only issues assigned to the current user
- Any other string: filter by that person's display name
- `--filter <id>`: run a Jira saved filter by ID (e.g. `--filter 10363`). When set, the skill skips project/sprint resolution entirely and runs the saved filter's JQL. The assignee filter and `--all` still apply.
- `--all`: bypass the 50-issue cap and fetch everything (paginate if needed)

### 1. Load Jira config from memory

Check memory file `jira_config.md` for:
- `JIRA_BASE_URL`
- `JIRA_EMAIL`

If not found, ask the user and save to memory (same as `create` verb).

Require `JIRA_API_TOKEN` env var. If not set, tell the user to set it and stop.

### 2. Resolve project key

Same as `create` verb: git history → `jira_project.md` memory → ask user.

**Skip this step entirely when `--filter <id>` is set** — a saved filter carries its own scope.

### 3. Resolve assignee filter

Walk the args once and extract flags, then treat the remainder as the assignee filter:

- If `--all` is present anywhere, set `FETCH_ALL=true` and strip it.
- If `--filter <id>` is present, capture the integer ID into `SAVED_FILTER_ID` and strip both tokens.
- Remainder rules for the assignee filter:
  - No remainder → no assignee filter (show all)
  - `me` → use `JIRA_EMAIL` from memory as the assignee value
  - Any other string → use as the assignee display name in JQL

### 3.5. Resolve saved filter (only when `--filter <id>` is set)

Fetch the saved filter's JQL and human name:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/filter/SAVED_FILTER_ID" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('name') or '') + '|' + (d.get('jql') or ''))
"
```

Capture `FILTER_NAME` and `FILTER_JQL`. If the call fails (404 / no JQL), stop and report the filter ID was not reachable.

When `SAVED_FILTER_ID` is set, **skip step 4 (Fetch active sprint) entirely** — the saved filter's JQL is the scope.

### 4. Fetch active sprint

**a. Get board ID:**

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/agile/1.0/board?projectKeyOrId=PROJECT_KEY" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['values'][0]['id']) if d.get('values') else print('')"
```

**b. Get active sprint (only if board found):**

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/agile/1.0/board/BOARD_ID/sprint?state=active" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
sprints=d.get('values',[])
if sprints:
    s=sprints[0]
    print(s['name'] + '|' + s.get('startDate','') + '|' + s.get('endDate',''))
else:
    print('')
"
```

If no board or no active sprint, set `HAS_SPRINT=false` and use fallback JQL.

### 5. Fetch issues via JQL

Build JQL based on the resolved scope and assignee filter:

- **With saved filter:** `(FILTER_JQL)` — wrap the fetched JQL in parens so later `AND` clauses bind correctly. Any `ORDER BY` clause already inside `FILTER_JQL` must be stripped before wrapping (the skill appends its own).
- **With sprint:** `sprint in openSprints() AND project=PROJECT_KEY`
- **Without sprint (fallback):** `project=PROJECT_KEY AND statusCategory in ("To Do","In Progress")`
- **Append assignee filter if set:**
  - `me` → `AND assignee="JIRA_EMAIL"`
  - other → `AND assignee="FILTER_STRING"`
- Always append: `ORDER BY status ASC, priority ASC`

When `FETCH_ALL=false` (default), pass `maxResults=50`. When `FETCH_ALL=true`, page through results using `nextPageToken` (Jira's `/search/jql` endpoint) until exhausted, accumulating issues before rendering. Use a per-page `maxResults=100` to cut round trips.

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" \
  --get \
  --data-urlencode "jql=CONSTRUCTED_JQL" \
  --data-urlencode "fields=summary,status,priority,assignee" \
  --data-urlencode "maxResults=50" \
  | python3 -c "
import sys, json
from collections import defaultdict

d = json.load(sys.stdin)
issues = d.get('issues', [])

CATEGORY_ORDER = {'To Do': 0, 'In Progress': 1, 'Done': 2}

groups = defaultdict(list)
for issue in issues:
    f = issue['fields']
    cat = f['status']['statusCategory']['name']
    priority_id = int(f['priority']['id']) if f.get('priority') else 99
    priority_name = f['priority']['name'] if f.get('priority') else 'None'
    assignee = f['assignee']['displayName'] if f.get('assignee') else 'unassigned'
    assignee_email = f['assignee'].get('emailAddress', '') if f.get('assignee') else ''
    groups[cat].append({
        'key': issue['key'],
        'summary': f['summary'][:50],
        'priority_name': priority_name,
        'priority_id': priority_id,
        'assignee': assignee,
        'assignee_email': assignee_email,
    })

for cat in sorted(groups.keys(), key=lambda c: CATEGORY_ORDER.get(c, 9)):
    items = sorted(groups[cat], key=lambda x: x['priority_id'])
    print(f'GROUP|{cat}|{len(items)}')
    for item in items:
        print(f'ISSUE|{item[\"key\"]}|{item[\"priority_name\"]}|{item[\"summary\"]}|{item[\"assignee\"]}|{item[\"assignee_email\"]}')
"
```

### 6. Render tree output

Format the parsed output as a tree. Claude renders this — not a script.

**Header:**
- With saved filter: `Filter <id>: <FILTER_NAME>`
- With sprint: `PROJECT — Sprint "Sprint Name" (start – end)`
- Without sprint: `PROJECT — Open Issues (no active sprint)`
- With assignee filter: append ` · filtered: @name`

**Status group icons:** To Do=📋, In Progress=🔨, Done=✅, any other=📌

**Issue lines:**
```
   ▸ ELROND-201  [Highest]  Implement patient alert system     @larry
```
- For the current user's In Progress items, add `→` prefix and `← YOU` suffix
- When filtered to one person, omit the `@name` column (redundant)
- Summaries truncated to 50 chars

**Example:**
```
ELROND — Sprint "Sprint 42" (Apr 7 – Apr 21)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 To Do (3)
   ▸ ELROND-201  [Highest]  Implement patient alert system     @larry
   ▸ ELROND-205  [High]     Add CSV export to reports          @david
   ▸ ELROND-210  [Medium]   Update onboarding copy             @unassigned

🔨 In Progress (2)
 → ▸ ELROND-198  [High]     Fix medication schedule overlap    @larry  ← YOU
   ▸ ELROND-203  [Medium]   Refactor notification service      @sarah

✅ Done (4)
   ▸ ELROND-195  [High]     Database migration for v2.3        @larry
```

### 7. Focus recommendation

Always based on the current user (from `JIRA_EMAIL`), regardless of filter applied.

After the tree, add a separator and recommendation:

```
─────────────────────────────────────────
💡 Working on: ELROND-198 — Fix medication schedule overlap
   Next up: ELROND-201 [Highest] — Implement patient alert system
```

**Logic:**
- Find user's In Progress items → list as "Working on:"
- If multiple: list all and add "Consider focusing on one at a time."
- Find user's highest-priority To Do item → show as "Next up:"
- If no In Progress and no To Do: "No tasks assigned. Pick one up or check with your team."
- If all user tasks are Done: "All clear. Pick up unassigned items or help a teammate."

## Rules

- Never ask the user to confirm the project key if it was found in git history
- Always check memory before asking the user for config values
- If `JIRA_API_TOKEN` is missing, stop and tell the user — do not proceed
- Sprint selection is only shown if a board with sprints exists for the project
- The focus recommendation always refers to the current user, regardless of the assignee filter
- When no board/sprint exists, fall back gracefully to open issues query
- Truncate issue summaries at 50 chars in tree display
- When `FETCH_ALL=false` and the page is full (50 issues returned), add a footer: "Showing first 50. Re-run with `--all` to fetch everything, or use an assignee filter to narrow." When `FETCH_ALL=true`, omit the cap footer and instead show the total count fetched.
- `--filter <id>` takes precedence over project/sprint resolution: when set, project key is not resolved, sprint is not fetched, and the saved filter's JQL becomes the scope. The assignee filter and `--all` still layer on top.
