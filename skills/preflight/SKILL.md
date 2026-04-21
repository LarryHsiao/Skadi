---
name: preflight
description: Run periodic maintenance checks. Use /preflight to see the checklist — rows highlighted if overdue (e.g. /cleanup-dev > 30 days).
user_invocable: true
---

# Preflight

Runs a checklist of periodic maintenance tasks and reports which are overdue.

## Workflow

### 1. Gather state

```bash
~/.claude/hooks/preflight-check.sh
```

Output is pipe-delimited `check|status|detail|flag`. `flag=warn` means the row is overdue and should be highlighted.

### 2. Present as a table

Columns: **Check**, **Status**, **Detail**, **Action**.

- Bold the **Check** cell and prefix the **Status** cell with a warning marker (e.g. `⚠️` or `**OVERDUE**`) when `flag=warn`.
- **Action** suggests the corresponding slash command (e.g. `/cleanup-dev` for an overdue cleanup row).
- For clean rows, leave Action empty or show `—`.

### 3. Offer to run overdue items

If any rows are flagged, ask (AskUserQuestion) whether to run each overdue task now. Invoke the suggested slash command for any the user approves.

## Checks

| Key | Threshold | Action when overdue |
|-----|-----------|---------------------|
| `cleanup-dev` | 30 days since last run | `/cleanup-dev` |

Add new checks by extending `~/.claude/hooks/preflight-check.sh` and the table above.
