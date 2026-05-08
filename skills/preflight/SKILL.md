---
name: preflight
description: Run periodic maintenance checks. Use /preflight to see the checklist — rows highlighted if overdue (e.g. /cleanup-dev > 30 days). Overdue items are synced into the built-in todo list.
user_invocable: true
---

# Preflight

Runs a checklist of periodic maintenance tasks, reports which are overdue, and syncs them into the built-in todo list so the count is visible at a glance.

## Workflow

### 1. Gather state

```bash
~/.claude/hooks/preflight-check.sh
```

Output is pipe-delimited `check|status|detail|flag`. `flag=warn` means the row is overdue.

### 2. Present as a table

Columns: **Check**, **Status**, **Detail**, **Action**.

- Bold the **Check** cell and prefix the **Status** cell with `⚠️ **OVERDUE**` when `flag=warn`.
- **Action** suggests the matching slash command (e.g. `/cleanup-dev`). Clean rows show `—`.
- End with a one-line summary: `N overdue / M checks`.

### 3. Sync with the todo list

Call **TaskList** to get current tasks. A preflight task is any task whose `metadata.preflight_key` matches a check key.

For each check:

- **Overdue (`flag=warn`)**:
  - If no pending preflight task exists for this key → **TaskCreate**:
    - `subject`: `<key> overdue — run <action>` (e.g. `cleanup-dev overdue — run /cleanup-dev`)
    - `description`: the row's detail field plus the suggested slash command
    - `metadata`: `{ "preflight_key": "<key>" }`
  - If a pending preflight task already exists for this key → do nothing (don't duplicate).

- **Clean**:
  - If a pending preflight task exists for this key → **TaskUpdate** `status=completed` (self-heal: the check is no longer overdue).

Never touch tasks without a `preflight_key` in their metadata.

### 4. Offer to run overdue items

If any rows are flagged, use AskUserQuestion to let the user pick which overdue tasks to run now (multiSelect). Invoke the suggested slash command for each selection.

When a run finishes, the next `/preflight` invocation will auto-complete the corresponding task via the self-heal in step 3. No per-skill coupling needed.

## Checks

| Key | Threshold | Action when overdue |
|-----|-----------|---------------------|
| `cleanup-dev` | 30 days since last run | `/cleanup-dev` |
| `daily` | not yet run today (calendar day) | `/daily` |
| `triage` | not yet run today (calendar day) | `/triage` |
| `vocab` | any card with `due_in_days <= 0` | `/vocab review` |
| `nazgul-checks` | 30 days since last review of the rubric files | walk `skills/nazgul/checks/*.md`, then `/nazgul reviewed` |
| `palantir` | any of your PRs/MRs carries new comments since you last looked | `/palantir activity` |

Add new checks by extending `~/.claude/hooks/preflight-check.sh` and the table above.
