---
name: working
description: Use when the user runs /working [[tracker:]ticket-id] [type] to begin a Jira or YouTrack ticket. Resolves the ticket (prompts a list when none given), checks out an existing feature branch or cuts a new one from the chosen base, moves the ticket to In Progress on its tracker, then pushes the branch and opens a draft PR/MR self-assigned to the author — a GitHub PR via `gh` or a GitLab MR via `glab`, whichever the origin remote points to — when the forge CLI is authenticated.
purpose: Begins a Jira or YouTrack ticket — branches, transitions status, and opens a draft PR/MR.
stage: forge
---

# Start Working on a Ticket

Creates and checks out a git branch for a Jira or YouTrack ticket. `JIRA-NUMBER` below names the ticket ID whichever tracker holds it (`PSG-123`, `MET-42`).

## Tracker routing

Two trackers are wired:

| Tracker | Open list | Ticket | Move to In Progress | Ticket link |
|---|---|---|---|---|
| Jira | `working-jira-open.sh` | `working-jira-ticket.sh` | `working-jira-transitions.sh` + `jira-state.sh` | `<jira-uri>/browse/<ID>` |
| YouTrack | `working-youtrack-open.sh` | `working-youtrack-ticket.sh` | `youtrack-state.sh` | `<youtrack-uri>/issue/<ID>` |

Each pair of list/ticket hooks shares one output contract, so every step below is tracker-blind except where it names a branch.

Resolve the tracker with `/council`'s hybrid dispatch, in this order:

1. **Explicit prefix.** `youtrack:MET-42`, `yt:MET-42`, or `jira:PSG-123` (case-insensitive) wins. Strip the prefix; the remainder is the ticket ID.
2. **Per-project memory.** Read `tracker_routing.md` from the project memory directory and match the ticket's project prefix (`MET-42` → `MET`) against its lines (`- MET → youtrack`).
3. **Ask.** Neither found — ask via AskUserQuestion which tracker holds the project, then offer to append the mapping to `tracker_routing.md` (create it with the frontmatter `/council` documents, and add a pointer to `MEMORY.md`).

With no ticket argument, resolve the project key first (step 1a), then route that key by rules 2–3.

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

- If `JIRA-NUMBER` was provided (e.g., `PROJ-123`, or `yt:MET-42`), resolve its tracker per *Tracker routing*, use it, and skip the rest of this step.
- If `type` was also provided alongside the ticket (`/working PROJ-123 feat`), record it for step 5 (and skip the prompt there).

**If no ticket number was provided:**

**a. Resolve the project key** (creds are the hook's concern, resolved via `secret.sh`):

1. Check memory file `jira_project.md` for a saved project key.
2. If not found, search git history and branches for a ticket pattern (`[A-Z]+-[0-9]+`):
   ```bash
   git log --oneline -100 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
   git branch -a 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
   ```
   Extract the project key (e.g. `PROJ` from `PROJ-123`).
3. If still not found, ask the user for the project key via AskUserQuestion, then save to memory:
   - Write `jira_project.md` to the current project's auto-memory directory (the `memory/` path named in the system prompt)
   - Add pointer to `MEMORY.md`
4. Route the resolved key per *Tracker routing* rules 2–3 (`jira_project.md` keeps its name for either tracker — it holds the project key).

**b. Fetch open/in-progress tickets for the project** from the routed tracker and present them for selection:

```bash
~/.claude/hooks/working-jira-open.sh PROJECT_KEY 20      # Jira
~/.claude/hooks/working-youtrack-open.sh PROJECT_KEY 20  # YouTrack
```

Each hook resolves its creds via `secret.sh` and prints a JSON array, most-recently-updated first:
`[{"key":"ELROND-148","status":"To Do","summary":"..."}]`. Jira lists the To Do and In Progress status categories; YouTrack lists every unresolved ticket. On failure it prints `{"error":"..."}`.

Present the results via AskUserQuestion (up to 4 options; if more than 4, show the first 4 — already the most recently updated — and offer "Other" for manual entry). Use the ticket key + summary as the label.

Set the chosen ticket as `JIRA-NUMBER` and continue.

### 2. Check for existing branch

Before fetching any ticket data, check if a branch for this ticket already exists:

```bash
git branch -a --format='%(refname:short)' | grep -iE '(^|/)JIRA-NUMBER/'
```

The `(^|/)JIRA-NUMBER/` anchor matches the ticket key only as a whole branch segment — `PROJ-12` will not match `PROJ-123/...`. The trailing `/` is the branch-format separator (`JIRA-NUMBER/type/...`).

- **No matches** → continue to step 3.
- **Exactly one match** → check it out and stop:
  ```bash
  git checkout <branch>
  git pull
  ```
- **Multiple matches** → present them via AskUserQuestion, let the user pick one, check it out with `git pull`, then stop.

If the user picks an existing branch, the workflow ends here — no tracker API calls, no new branch.

### 3. Get the ticket description

Fetch the ticket fields through the routed tracker's hook — each resolves its creds via `secret.sh` (Vaultwarden first, env fallback), so no token need live in the skill:

```bash
~/.claude/hooks/working-jira-ticket.sh JIRA-NUMBER      # Jira
~/.claude/hooks/working-youtrack-ticket.sh JIRA-NUMBER  # YouTrack
```

Each pulls summary, status, description, priority, and type in one call and prints a single JSON object — the brief in step 8e needs all five. Jira's description arrives flattened from ADF (Atlassian Document Format) to plain text; YouTrack's is its markdown as stored, and its status, type, and priority are the `State`, `Type`, and `Priority` custom fields:

```json
{"summary":"...","status":"...","type":"...","priority":"...","description":"..."}
```

On failure it prints `{"error":"...","response":"..."}`.

Stash all five values for use in the step 4 transition (status), the step 8e brief (everything), and the step 8f PR/MR title (summary).

If the hook returns an error, fall back to asking:
> "What is the ticket title/description for [JIRA-NUMBER]?"

When the error names missing credentials, also tell the user the routed tracker's line:
> Jira creds resolve via `secret.sh` — store a Vaultwarden item `jira` (uri / username / password), or set `JIRA_API_TOKEN` in your environment. An Atlassian API token comes from https://id.atlassian.com/manage-profile/security/api-tokens

> YouTrack creds resolve via `secret.sh` — store a Vaultwarden item `youtrack` (uri / password holding a permanent token), or set `YOUTRACK_URL` and `YOUTRACK_TOKEN` in your environment.

### 3b. Readiness check (only when the goal is obvious)

Read the summary and description stashed in step 3. Run this check only if the goal is obvious: you can write, without guessing, one sentence saying what is different when the work is done. If you cannot, print `Goal not evident from the ticket; skipping readiness check.` and continue to step 4. Do not infer a goal in order to analyze it.

When the goal is obvious, answer from the ticket text alone:

1. Is each acceptance line an observable outcome?
2. Is the scope bounded?
3. Are blockers and unknowns named?
4. Does the description say everything the goal needs?

Print `READY` on one line only if all four answer yes, and continue to step 4; otherwise print `GAPS` with each gap quoting the ticket line it rests on. A gap with no quote is dropped. Never edit the ticket. After `GAPS`, ask via AskUserQuestion: proceed, or stop here.

### 4. Transition ticket to "in progress"

Throughout this step the **in-progress keyword set** is `progress`, `doing`, `active`, `start`, `working` (case-insensitive substring match — `start` also catches "started").

Skip steps a–c entirely if the current status (stashed in step 3) already contains one of those keywords.

**YouTrack** takes a state name, not a transition ID, so it replaces steps a–c with one call:

- Read `youtrack_state_PROJECTKEY.md` from memory for the project's in-progress state name; absent, use `In Progress`.
- Apply it — idempotent, so it no-ops when the ticket is already there:

  ```bash
  ~/.claude/hooks/youtrack-state.sh JIRA-NUMBER "STATE_NAME"
  ```

  It prints `transitioned: id=… state=…->…`, `noop: id=… state=…`, or `{"error":"..."}`. Confirm silently.
- On an error naming the state (the project calls it something else), ask the user for the state name via AskUserQuestion, retry once, and on success save it as `youtrack_state_PROJECTKEY.md` in the project's auto-memory directory with a pointer in `MEMORY.md`.

Then continue at step d. Jira follows a–c:

**a. Check memory for a saved transition** (`jira_transition_PROJECTKEY.md`, where PROJECTKEY is the project part of the ticket number, e.g. `ELROND`):
- If a transition ID is saved, use it directly — go to step 4c.

**b. Fetch available transitions** through the hook:

```bash
~/.claude/hooks/working-jira-transitions.sh JIRA-NUMBER
```

It prints a JSON array `[{"id":"42","name":"Doing","to":"Doing"}]` (creds via `secret.sh`); on failure, `{"error":"..."}`.

- Identify candidates whose name contains a keyword from the in-progress set.
- If exactly one candidate is found, use it automatically.
- If multiple candidates are found, present them via AskUserQuestion and let the user pick.
- If no candidates are found, present all available transitions via AskUserQuestion.
- After the user picks, save the chosen transition ID to memory:
  - Write `jira_transition_PROJECTKEY.md` to the current project's auto-memory directory (the `memory/` path named in the system prompt)
  - Add pointer to `MEMORY.md` (only if not already listed)

**c. Apply the transition** through the hook — idempotent, so it no-ops when the ticket is already in the target status:

```bash
~/.claude/hooks/jira-state.sh JIRA-NUMBER TRANSITION_ID
```

It prints `transitioned: id=… status=…->…` on success, `noop: id=… status=…` when already there, or `{"error":"..."}` on failure. Confirm silently — surface only an error.

**d. Mark the ticket in progress on the session's task surface:**

Conditional on the session — read `docs/workflow/task-surface.md` for the convention. In short: a
task-tracking tool in the roster carries the ticket as in-progress work; absent
one, skip this silently — the tracker's state is the authoritative record
either way.

Where a tool is used, look first for an item bearing `jira_key = JIRA-NUMBER` —
`/daily` may have seated it already, and it is advanced rather than duplicated:

- **Found** → move it to in progress.
- **Not found** → add it, then move it to in progress:
  - `subject`: `JIRA-NUMBER — SUMMARY` (truncate to ~55 chars)
  - `description`: the ticket link from the *Tracker routing* table (uri from `~/.claude/hooks/secret.sh jira uri` or `secret.sh youtrack uri`)
  - identity: `jira_key = JIRA-NUMBER` (the key keeps its name for YouTrack tickets too — it holds the ticket ID)

Silent on success.

### 5. Ask for type (if not provided)

Use AskUserQuestion:
- `feat` — new feature or user-facing change
- `fix` — bug fix
- `chore` — maintenance, dependency update, refactor, CI, etc.

### 6. Get the user's name/handle

- Check memory file `user_jira_name.md` for a saved name — if found, use it silently, do NOT ask
- If not saved, ask once: "What name/handle should appear in branch names?" then save it:
  - Write `user_jira_name.md` to the current project's auto-memory directory (the `memory/` path named in the system prompt)
  - Add pointer to `MEMORY.md`
- Only re-ask if the user explicitly says to change it (e.g. "change my name", "use a different handle")

### 7. Slugify the description

- If not in English, translate to English first
- Lowercase everything
- Replace spaces and special characters with `-`
- Remove characters that aren't alphanumeric or `-`
- Trim leading/trailing `-`
- Truncate to ~50 characters at a word boundary

### 8. Choose base branch and create feature branch

**a. Load default dev branch from memory** (`dev_branch.md`):
- If not saved, ask: "What is the default dev branch for this project? (e.g. `dev`, `develop`, `main`)"
  - Save the answer as `dev_branch.md` in the current project's auto-memory directory (the `memory/` path named in the system prompt)
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

**e. Brief the ticket:**

Render a tight ticket card in chat so the user is oriented before they start coding. Use the values stashed in step 3.

```
─ JIRA-NUMBER ───────────────────────────
**<summary>**
<type> · <priority> · <status> · <branch-name>

<description, truncated to 800 chars; append "..." if cut>
─────────────────────────────────────────
```

Truncate the description at the nearest whitespace at-or-before 800 chars (don't cut mid-word). If any of `type`, `priority`, or `status` is empty, omit it from the metadata line — keep the dots clean.

**f. Push the branch and open a draft PR/MR — host-agnostic:**

Detect the forge from the origin remote, then hand the push and draft-open to the matching forge hook. Each hook pushes the branch, opens the PR/MR self-assigned to `@me`, and prints one line — `opened: forge=<github|gitlab> url=<url> number=<n>` — or `{"error":"..."}` on failure. The two hooks share one argument contract, so the skill is forge-blind below the detection.

```bash
origin=$(git remote get-url origin)
```

Pick the hook from the remote — both share one argument contract, so the rest of the step is forge-blind:

- `origin` contains `gitlab` → `FORGE_HOOK=~/.claude/hooks/forge-gitlab-mr.sh`
- `origin` contains `github` → `FORGE_HOOK=~/.claude/hooks/forge-github-pr.sh`
- otherwise → skip the push and PR/MR; tell the user the forge wasn't recognized. The feature branch is already created locally regardless.

Build a short draft body (the ticket link and summary — the work isn't done yet, so the body fills out at review time) and invoke the chosen hook with the body on stdin, targeting the base branch from step 8b. The link line follows the routed tracker:

- Jira → `Jira: <jira-uri>/browse/JIRA-NUMBER`, uri from `~/.claude/hooks/secret.sh jira uri`
- YouTrack → `YouTrack: <youtrack-uri>/issue/JIRA-NUMBER`, uri from `~/.claude/hooks/secret.sh youtrack uri`

```bash
ticket_link="..."  # the link line above
printf '%s\n\n%s\n' "$ticket_link" "TICKET_SUMMARY" \
  | "$FORGE_HOOK" \
      JIRA-NUMBER/type/name/description-slug \
      BASE_BRANCH \
      "[JIRA-NUMBER] type: Ticket summary" \
      --draft --assignee @me
```

- **Title** format: `[JIRA-NUMBER] type: <ticket summary>` — the original ticket summary (not the slug), sentence-case.
- **Base**: the branch chosen in step 8b.
- The hook self-checks that `gh`/`glab` is installed and authenticated; on a missing CLI or failed auth it prints `{"error":"..."}` — surface that and stop. The branch is created locally either way.
- Read the `opened:` line and show the user the PR/MR URL.

## Rules

- Jira number: preserve case as given (e.g., `PROJ-123`, not `proj-123`)
- Type: must be exactly `feat`, `fix`, or `chore`
- Name: lowercase, from memory
- Description: English slug only — no spaces, no special chars, hyphens between words
