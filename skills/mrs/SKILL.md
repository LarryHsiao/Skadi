---
name: mrs
description: Use when the user runs /mrs [...args]. Shows open GitLab merge requests requiring attention — MRs where you are a reviewer, and MRs you authored. Args: `review`, `mine`, or `GROUP/PROJECT` to scope. Example: /mrs, /mrs review, /mrs mine, /mrs group/project.
user_invocable: true
---

# Merge Request Check

Lists open GitLab MRs that need your attention, grouped by category.

## Argument Parsing

Arguments: `/mrs [mode] [GROUP/PROJECT]`

- `review` → only MRs with you as reviewer
- `mine` → only MRs you authored
- `GROUP/PROJECT` (contains `/`) → scope to a single project
- No args → both categories, global scope

Examples:
- `/mrs` → reviewer + mine, all projects
- `/mrs review` → only where you're a reviewer
- `/mrs mine` → only your open MRs
- `/mrs group/project` → both, scoped to one project

---

## Workflow

### 1. Verify glab auth

The hook script calls `glab api user` first. If auth fails, it prints:
> glab auth failed — run: glab auth login

Relay that to the user and stop.

### 2. Fetch MRs

Use the pre-approved hook script:

```bash
~/.claude/hooks/mrs-check.sh [mode] [GROUP/PROJECT]
```

Output is pipe-delimited: `category|project|iid|title|web_url|isDraft|pipeline`
- `category`: `review` or `mine`
- `pipeline`: `ok` | `processing` | `failed` | `cancelled` | `none`

### 3. Render output

Group by category. Order: **Review → Mine**. Omit empty groups.

**Header:**
```
Open Merge Requests (N)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Body:**
```
Review
  ◆ ✅ group/project!123  Title of the MR
  ◆ 🔄 group/project!456  Another title
Mine
  ▶ 🚫 group/project!14   My open MR
  ⋯ ⚪ group/project!17   Draft MR title
```

- `◆` — you are a reviewer
- `▶` — your open non-draft MR
- `⋯` — your draft MR (isDraft=true)
- Pipeline icon (after the category symbol):
  - `✅` — `ok` (latest pipeline succeeded)
  - `🔄` — `processing` (running, pending, scheduled, manual, etc.)
  - `🚫` — `failed`
  - `⏹` — `cancelled`
  - `⚪` — `none` (no pipeline configured for this MR)
- Reference format: `project!iid` (GitLab convention)
- Title truncated to 55 chars
- Show `web_url` under an entry only if the user asks for details

**Footer:**
```
───────────────────────────────────────────
  N review · N mine
```

**Special cases:**

If the script outputs nothing:
```
Open Merge Requests
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
No MRs need your attention.
```

If `glab auth failed` is printed:
> glab auth expired. Run `glab auth login` and try again.

## Rules

- Read-only — never approves, merges, or comments on MRs
- Pipeline state is fetched per MR (one detail call apiece); approvals are not
- Sort within a category by project path then iid ascending
