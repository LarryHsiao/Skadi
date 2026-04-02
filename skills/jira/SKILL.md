---
name: jira
description: Use when the user runs /jira [verb] [...args]. Supported verbs: create. Example: /jira create, /jira create bug, /jira create bug Fix login crash.
---

# Jira Skill

Dispatches to a Jira action based on the verb argument.

## Argument Parsing

Arguments: `/jira [verb] [...rest]`

- `verb`: the action to perform. Supported values: `create`
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
- Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_config.md`
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
  - Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_project.md`
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

## Rules

- Never ask the user to confirm the project key if it was found in git history
- Always check memory before asking the user for config values
- If `JIRA_API_TOKEN` is missing, stop and tell the user — do not proceed
- Sprint selection is only shown if a board with sprints exists for the project
