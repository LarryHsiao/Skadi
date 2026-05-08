---
name: prs
description: Use when the user runs /prs [...args]. Shows open GitHub PRs requiring attention — PRs where review is requested from you, and PRs you authored. Args: `review`, `mine`, or `OWNER/REPO` to scope. Example: /prs, /prs review, /prs mine, /prs LarryHsiao/skadi.
user_invocable: true
---

# Pull Request Check

Lists open PRs that need your attention, grouped by category.

## Argument Parsing

Arguments: `/prs [mode] [OWNER/REPO]`

- `review` → only PRs with review requested from you
- `mine` → only PRs you authored
- `OWNER/REPO` (contains `/`) → scope to a single repo
- No args → both categories, all repos

Examples:
- `/prs` → review-requested + mine, all repos
- `/prs review` → only review-requested
- `/prs mine` → only my open PRs
- `/prs LarryHsiao/skadi` → both, scoped to one repo
- `/prs review LarryHsiao/skadi` → review-requested in one repo

---

## Workflow

### 1. Verify gh auth

If `gh auth status` reports not logged in, stop and tell the user:
> Run `gh auth login` first.

### 2. Fetch PRs

Use the pre-approved hook script:

```bash
~/.claude/hooks/prs-check.sh [mode] [OWNER/REPO]
```

Output is pipe-delimited: `category|repo|number|title|url|isDraft|pipeline`
- `category`: `review` or `mine`
- `pipeline`: `ok` | `processing` | `failed` | `cancelled` | `none`

### 3. Render output

Group by category. Order: **Review Requested → Mine**. Omit empty groups.

**Header:**
```
Open Pull Requests (N)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Body:**
```
Review Requested
  ◆ ✅ OWNER/REPO#123  Title of the PR
  ◆ 🔄 OWNER/REPO#456  Another title
Mine
  ▶ 🚫 OWNER/REPO#14   Dependenceise
  ⋯ ⚪ OWNER/REPO#17   Draft PR title
```

- `◆` — review requested from you
- `▶` — your open non-draft PR
- `⋯` — your draft PR (isDraft=true)
- Pipeline icon (after the category symbol):
  - `✅` — `ok` (status check rollup succeeded)
  - `🔄` — `processing` (any check still in_progress / queued / pending)
  - `🚫` — `failed`
  - `⏹` — `cancelled` (every check was cancelled)
  - `⚪` — `none` (no checks configured)
- Title column: truncate to 55 chars
- Show URL under each entry only if the user asks for details

**Footer:**
```
───────────────────────────────────────────
  N review requested · N mine
```

**Special cases:**

If output is empty:
```
Open Pull Requests
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
No PRs need your attention.
```

If the hook script errors:
> `gh` query failed. Check `gh auth status` and your network.

## Rules

- Read-only — never opens, merges, or comments on PRs
- Status check rollup is fetched per PR (one detail call apiece); reviews are not
- Sort within a category by repo name then PR number ascending
