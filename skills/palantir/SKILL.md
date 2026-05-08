---
name: palantir
description: Use when the user runs /palantir [...args]. Looks across both forges from one stone — open GitHub PRs and GitLab MRs needing your attention, in one combined view, with new-activity flags. Args: `github` (`gh`) or `gitlab` (`gl`) to scope to one forge; `review`, `mine`, or `activity` to filter category. Examples: /palantir, /palantir github, /palantir gitlab review, /palantir activity.
user_invocable: true
---

# Palantír — Cross-Forge PR/MR View

Looks across both forges from one stone. Open GitHub PRs and GitLab MRs needing attention, rendered as one combined list. Each row may carry a `⚑` flag if the platform reports unread activity on it.

## Argument Parsing

Arguments: `/palantir [forge] [mode]` — order-independent, both optional.

- `github` (alias `gh`) → only GitHub PRs
- `gitlab` (alias `gl`) → only GitLab MRs
- `review` → only items where review is requested from you
- `mine` → only items you authored
- `activity` → only items carrying `⚑`
- No args → both forges, all categories, flags on rows with activity

Examples:
- `/palantir` — both forges, all attention
- `/palantir github` — only GitHub
- `/palantir gitlab review` — GitLab MRs awaiting your review
- `/palantir activity` — only items with new comments
- `/palantir mine` — both forges, only authored

---

## Workflow

### 1. Decide which forges to query

- No forge arg → query both
- `github` / `gh` → query only the GitHub side
- `gitlab` / `gl` → query only the GitLab side

### 2. Verify auth (only for forges to be queried)

- For GitHub: if `gh auth status` errors, mark GitHub as unavailable.
- For GitLab: if the MR hooks print `glab auth failed`, mark GitLab as unavailable.

If a forge is unavailable, render the other; the footer carries one line naming the gap. If both fail, render only:

> Both forges failed to authenticate. Run `gh auth login` and `glab auth login`.

### 3. Fetch list and activity

For each queried forge, call its check hook and its activity hook:

```bash
~/.claude/hooks/prs-check.sh [mode]      # category|repo|number|title|url|isDraft|pipeline
~/.claude/hooks/prs-activity.sh           # repo|number
~/.claude/hooks/mrs-check.sh [mode]      # category|project|iid|title|web_url|isDraft|pipeline
~/.claude/hooks/mrs-activity.sh           # project|iid
```

`pipeline` is one of `ok` | `processing` | `failed` | `cancelled` | `none`.

`mode` for the check hooks is `review` or `mine` if the user passed either. For `activity` or no mode, omit the mode arg so both categories return.

If an activity hook exits non-zero, render the list without flags for that forge and footer-note:

- GitHub failure → *"activity check skipped — try `gh auth refresh -s notifications`."*
- GitLab failure → *"activity check skipped — `glab` token lacks `read_api`."*

### 4. Cross-reference

Build an activity set per forge — `{repo|number}` for GitHub, `{project|iid}` for GitLab. For each row from the check hook, set `hasActivity = true` when its identifier is in the corresponding activity set.

For `mode=activity`, drop rows where `hasActivity = false`.

### 5. Render

Group: forge → category → rows. Omit empty groups.

**Header:**

```
Palantír (N)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

`N` — total rows after the activity filter (if any).

**Body — GitHub section:**

```
GitHub
  Review Requested
    ◆⚑ ✅ OWNER/REPO#123  Title of the PR
    ◆  🔄 OWNER/REPO#456  Quiet PR with running checks
  Mine
    ▶⚑ 🚫 OWNER/REPO#14   My PR with new comments and red checks
    ⋯  ⚪ OWNER/REPO#17   Draft, no traffic, no CI
```

**Body — GitLab section:**

```
GitLab
  Review
    ◆⚑ ✅ group/project!88  Threaded discussion advanced
  Mine
    ▶  ⏹ group/project!14  Quiet MR with cancelled pipeline
```

Symbols:

- `◆` — review requested from you
- `▶` — your open non-draft
- `⋯` — your draft (`isDraft = true`)
- `⚑` — new activity since you last looked
- Pipeline icon (after the activity column):
  - `✅` — `ok`
  - `🔄` — `processing`
  - `🚫` — `failed`
  - `⏹` — `cancelled`
  - `⚪` — `none` (no pipeline / no checks configured)

If a row has activity, `⚑` immediately follows the category symbol; otherwise a single space sits in its place so columns align. The pipeline icon follows after a single space.

Reference format: `OWNER/REPO#num` for GitHub, `project!iid` for GitLab. Title truncated to 55 chars.

**Footer:**

```
───────────────────────────────────────────
  GitHub: N review · N mine    GitLab: N review · N mine    ⚑ N with new activity
```

Omit a forge half if it returned nothing or was skipped. Omit `⚑ N with new activity` if the count is zero.

If a forge's activity check was skipped, append on its own line:

```
  Note: GitLab activity check skipped — glab token lacks read_api.
```

**Special cases:**

- All forges and all categories empty:

  ```
  Palantír
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  The stones are clear — no PRs or MRs need your attention.
  ```

- `mode=activity` with no flagged rows:

  ```
  Palantír — activity
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  No new comments worth your eyes.
  ```

## Rules

- Read-only — orchestrates four hooks; never opens, merges, comments, approves, or marks notifications/todos read
- Repo/project scoping is not supported here — use `/prs OWNER/REPO` or `/mrs GROUP/PROJECT` for that
- Pipeline state is fetched per row by the check hooks; reviews and approvals are not
- Sort within a category by repo/project path, then number/iid ascending
