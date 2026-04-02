---
name: working
description: Use when the user runs /working [JIRA-number] or /working [JIRA-number] [type] to start working on a Jira ticket.
---

# Start Working on a Jira Task

Creates and checks out a git branch for a Jira ticket.

## Branch Format

```
JIRA-NUMBER/type/name/description-slug
```

Examples:
```
PROJ-123/feat/larry/add-user-authentication
PROJ-456/chore/larry/update-ci-pipeline
PROJ-789/fix/larry/cannot-close-emergency-measure-page
```

## Workflow

### 1. Parse command arguments and resolve ticket number

- If `JIRA-NUMBER` was provided (e.g., `PROJ-123`), use it and skip the rest of this step.
- If `type` was also provided alongside the ticket (`/working PROJ-123 feat`), record it for step 4.

**If no ticket number was provided:**

**a. Load Jira config from memory** (`jira_config.md`) and resolve the project key:

1. Check memory file `jira_project.md` for a saved project key.
2. If not found, search git history and branches for a Jira ticket pattern (`[A-Z]+-[0-9]+`):
   ```bash
   git log --oneline -100 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
   git branch -a 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
   ```
   Extract the project key (e.g. `PROJ` from `PROJ-123`).
3. If still not found, ask the user for the project key via AskUserQuestion, then save to memory:
   - Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_project.md`
   - Add pointer to `MEMORY.md`

**b. Fetch open/in-progress tickets for the project** and present them for selection:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/search?jql=project=PROJECT_KEY+AND+statusCategory+in+(\"To+Do\",\"In+Progress\")+ORDER+BY+updated+DESC&fields=summary,status&maxResults=20" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for i in d.get('issues',[]):
    print(i['key'], '|', i['fields']['status']['name'], '|', i['fields']['summary'])
"
```

Present the results via AskUserQuestion (up to 4 options; if more than 4, show the 4 most recently updated and offer "Other" for manual entry). Use the ticket key + summary as the label.

Set the chosen ticket as `JIRA-NUMBER` and continue.

### 2. Get Jira ticket description

Fetch the ticket summary from the Jira REST API:

**a. Load Jira config from memory** (`jira_config.md`):
- `JIRA_BASE_URL` — e.g. `https://company.atlassian.net`
- `JIRA_EMAIL` — e.g. `user@example.com`

If not saved, ask the user for their Jira domain and email, then save to memory:
- Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_config.md`
- Add pointer to `MEMORY.md`

**b. Fetch the ticket via API** (requires `JIRA_API_TOKEN` env var):

> Skip this fetch if the summary and status were already retrieved from the ticket list in step 1.

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/issue/JIRA-NUMBER?fields=summary,status" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('SUMMARY:', d['fields']['summary'])
print('STATUS:', d['fields']['status']['name'])
"
```

If `JIRA_API_TOKEN` is not set, tell the user:
> Set `JIRA_API_TOKEN` in your environment (e.g. in `~/.zshrc`) with an Atlassian API token from https://id.atlassian.com/manage-profile/security/api-tokens

If the API call fails (non-zero exit or error in response), fall back to asking:
> "What is the Jira ticket title/description for [JIRA-NUMBER]?"

### 3. Transition ticket to "in progress"

Skip this step if the current status already contains "progress", "doing", "active", or "started" (case-insensitive).

**a. Check memory for a saved transition** (`jira_transition_PROJECTKEY.md`, where PROJECTKEY is the project part of the ticket number, e.g. `ELROND`):
- If a transition ID is saved, use it directly — go to step 3c.

**b. Fetch available transitions:**

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/issue/JIRA-NUMBER/transitions" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for t in d.get('transitions',[]):
    print(t['id'], t['name'])
"
```

- Identify candidates whose name contains "progress", "doing", "active", "start", or "working" (case-insensitive).
- If exactly one candidate is found, use it automatically.
- If multiple candidates are found, present them via AskUserQuestion and let the user pick.
- If no candidates are found, present all available transitions via AskUserQuestion.
- After the user picks, save the chosen transition ID to memory:
  - Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_transition_PROJECTKEY.md`
  - Add pointer to `MEMORY.md` (only if not already listed)

**c. Apply the transition:**

```bash
curl -s -X POST \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"transition\": {\"id\": \"TRANSITION_ID\"}}" \
  "$JIRA_BASE_URL/rest/api/3/issue/JIRA-NUMBER/transitions"
```

Confirm success silently (no output to user unless it fails).

### 4. Ask for type (if not provided)

Use AskUserQuestion:
- `feat` — new feature or user-facing change
- `fix` — bug fix
- `chore` — maintenance, dependency update, refactor, CI, etc.

### 5. Get the user's name/handle

- Check memory file `user_jira_name.md` for a saved name — if found, use it silently, do NOT ask
- If not saved, ask once: "What name/handle should appear in branch names?" then save it:
  - Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/user_jira_name.md`
  - Add pointer to `MEMORY.md`
- Only re-ask if the user explicitly says to change it (e.g. "change my name", "use a different handle")

### 6. Slugify the description

- If not in English, translate to English first
- Lowercase everything
- Replace spaces and special characters with `-`
- Remove characters that aren't alphanumeric or `-`
- Trim leading/trailing `-`
- Truncate to ~50 characters at a word boundary

### 7. Check for existing branches with the same Jira ticket

Before creating a new branch, check if any local or remote branches already contain the Jira number:

```bash
git branch -a | grep -i "JIRA-NUMBER"
```

- **No matches** → proceed to step 8 (create a new branch)
- **Exactly one match** → ask the user: "Found existing branch `<branch>`. Switch to it, or create a new one?"
- **Multiple matches** → list all matches and use AskUserQuestion to let the user pick which branch to check out, or choose to create a new one

If the user picks an existing branch:
```bash
git checkout <chosen-branch>
git pull
```
Then stop — the workflow is done.

If the user chooses to create a new branch, continue to step 8.

### 8. Choose base branch and create feature branch

**a. Load default dev branch from memory** (`dev_branch.md`):
- If not saved, ask: "What is the default dev branch for this project? (e.g. `dev`, `develop`, `main`)"
  - Save the answer to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/dev_branch.md`
  - Add pointer to `MEMORY.md`
- Only re-ask if the user explicitly says to change it

**b. Ask which branch to start from** using AskUserQuestion (skip if user is switching to an existing branch):
- Default option: the remembered dev branch (from memory)
- Let the user pick a different branch or type a custom one

**c. Checkout and pull the chosen base branch:**

```bash
git checkout <chosen-branch>
git pull
```

**d. Create the feature branch:**

```bash
git checkout -b JIRA-NUMBER/type/name/description-slug
```

**e. Push the branch and open a draft MR on GitLab:**

First run these preflight checks. If any fail, skip the push and MR creation and tell the user why:

```bash
# 1. glab is installed
which glab

# 2. remote URL contains "gitlab"
git remote get-url origin | grep -qi gitlab

# 3. glab is authenticated
glab auth status
```

If all checks pass, push the branch and create the draft MR:

```bash
git push -u origin JIRA-NUMBER/type/name/description-slug
```

Look up the current user's GitLab username — first by email, then by name if email returns no results:

```bash
git_email=$(git config user.email)
git_name=$(git config user.name)

# Try email first
gitlab_users=$(glab api "users?search=$git_email" | python3 -c "import sys,json; [print(u['username']) for u in json.load(sys.stdin)]")

# Fall back to name if email found nothing
if [ -z "$gitlab_users" ]; then
  gitlab_users=$(glab api "users?search=$git_name" | python3 -c "import sys,json; [print(u['username']) for u in json.load(sys.stdin)]")
fi
```

- If exactly one result: use it as `gitlab_user` silently.
- If multiple results: present them via AskUserQuestion and let the user pick which one is them. Use the picked username as `gitlab_user`.
- If no results: omit `--assignee`.

Then create the MR assigned to that user (use `--assignee` if a username was found, omit if not):

```bash
glab mr create \
  --draft \
  --title "[JIRA-NUMBER] type: Ticket summary" \
  --target-branch BASE_BRANCH \
  --assignee USERNAME \
  --yes
```

- Title format: `[JIRA-NUMBER] type: <ticket summary>` — use the original ticket summary (not the slug), sentence-case
- `--target-branch` is the base branch chosen in step 8b
- `--yes` skips interactive prompts

## Rules

- Jira number: preserve case as given (e.g., `PROJ-123`, not `proj-123`)
- Type: must be exactly `feat`, `fix`, or `chore`
- Name: lowercase, from memory
- Description: English slug only — no spaces, no special chars, hyphens between words
