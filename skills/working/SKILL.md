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

### 1. Parse command arguments

- Extract `JIRA-NUMBER` from the command (e.g., `PROJ-123`)
- If `type` was also provided (`/working PROJ-123 feat`), use it; otherwise go to step 3

### 2. Get Jira ticket description

Fetch the ticket summary from the Jira REST API:

**a. Load Jira config from memory** (`jira_config.md`):
- `JIRA_BASE_URL` — e.g. `https://company.atlassian.net`
- `JIRA_EMAIL` — e.g. `user@example.com`

If not saved, ask the user for their Jira domain and email, then save to memory:
- Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/jira_config.md`
- Add pointer to `MEMORY.md`

**b. Fetch the ticket via API** (requires `JIRA_API_TOKEN` env var):

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/issue/JIRA-NUMBER?fields=summary" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['fields']['summary'])"
```

If `JIRA_API_TOKEN` is not set, tell the user:
> Set `JIRA_API_TOKEN` in your environment (e.g. in `~/.zshrc`) with an Atlassian API token from https://id.atlassian.com/manage-profile/security/api-tokens

If the API call fails (non-zero exit or error in response), fall back to asking:
> "What is the Jira ticket title/description for [JIRA-NUMBER]?"

### 3. Ask for type (if not provided)

Use AskUserQuestion:
- `feat` — new feature or user-facing change
- `fix` — bug fix
- `chore` — maintenance, dependency update, refactor, CI, etc.

### 4. Get the user's name/handle

- Check memory file `user_jira_name.md` for a saved name — if found, use it silently, do NOT ask
- If not saved, ask once: "What name/handle should appear in branch names?" then save it:
  - Write to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/user_jira_name.md`
  - Add pointer to `MEMORY.md`
- Only re-ask if the user explicitly says to change it (e.g. "change my name", "use a different handle")

### 5. Slugify the description

- If not in English, translate to English first
- Lowercase everything
- Replace spaces and special characters with `-`
- Remove characters that aren't alphanumeric or `-`
- Trim leading/trailing `-`
- Truncate to ~50 characters at a word boundary

### 6. Choose base branch and create feature branch

**a. Load default dev branch from memory** (`dev_branch.md`):
- If not saved, ask: "What is the default dev branch for this project? (e.g. `dev`, `develop`, `main`)"
  - Save the answer to `/Users/larryhsiao/.claude/projects/-Users-larryhsiao-skadi/memory/dev_branch.md`
  - Add pointer to `MEMORY.md`
- Only re-ask if the user explicitly says to change it

**b. Ask which branch to start from** using AskUserQuestion:
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

## Rules

- Jira number: preserve case as given (e.g., `PROJ-123`, not `proj-123`)
- Type: must be exactly `feat`, `fix`, or `chore`
- Name: lowercase, from memory
- Description: English slug only — no spaces, no special chars, hyphens between words
