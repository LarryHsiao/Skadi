#!/bin/bash
# Usage: echo "PR body markdown" | forge-github-pr.sh <branch> <base> <title> [--draft|--ready] [--assignee <user>]
#   <branch>      local branch carrying the commits to ship
#   <base>        branch to target the PR at (e.g. master, main)
#   <title>       one-line PR title
#   --draft       open as draft (default)
#   --ready       open as ready-for-review
#   --assignee U  assign the PR to user U (e.g. @me); omitted = unassigned
# Pushes the branch to origin, then opens a PR via `gh`.
# On success prints one line: opened: forge=github url=<pr-url> number=<n>
# Two other lines exit 0 and change nothing: `skipped: forge=github reason=no-commits`
# (branch not ahead of base — nothing pushed) and `exists: forge=github url=<pr-url>`
# (an open PR for the branch already stands).
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.
# This hook does not handle credential resolution beyond what `gh` does on its own.

set -euo pipefail
export LC_ALL=C.UTF-8

BRANCH="${1:-}"
BASE="${2:-}"
TITLE="${3:-}"

if [[ -z "$BRANCH" || -z "$BASE" || -z "$TITLE" ]]; then
  echo '{"error":"usage: forge-github-pr.sh <branch> <base> <title> [--draft|--ready] [--assignee <user>] (body on stdin)"}'
  exit 1
fi
shift 3

DRAFT_FLAG="--draft"
ASSIGNEE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --draft|--ready)
      DRAFT_FLAG="$1"
      shift
      ;;
    --assignee)
      ASSIGNEE="${2:-}"
      if [[ -z "$ASSIGNEE" ]]; then
        echo '{"error":"--assignee requires a value"}'
        exit 1
      fi
      shift 2
      ;;
    *)
      jq -cn --arg a "$1" '{error: ("unknown arg: " + $a + " (expected --draft|--ready|--assignee <user>)")}'
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo '{"error":"gh CLI not found on PATH"}'
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo '{"error":"gh is not authenticated; run `gh auth login` first"}'
  exit 1
fi

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  jq -cn --arg b "$BRANCH" '{error: ("local branch not found: " + $b)}'
  exit 1
fi

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  jq -cn --arg b "$BASE" '{error: ("base branch not found locally: " + $b + "; fetch it first")}'
  exit 1
fi

# Body via stdin → tempfile, normalised to UTF-8.
body_file=$(mktemp)
trap 'rm -f "$body_file" "${push_log:-}" "${create_log:-}"' EXIT
cat > "$body_file"

"$(dirname "$0")/body-to-utf8.sh" "$body_file" PR || exit 1

# Nothing to ship yet: a PR needs at least one commit past the base.
ahead=$(git rev-list --count "$BASE..$BRANCH")
if [[ "$ahead" -eq 0 ]]; then
  echo "skipped: forge=github reason=no-commits"
  exit 0
fi

# Re-run safety: an open PR for this branch is reported, never duplicated.
existing=$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  printf 'exists: forge=github url=%s\n' "$existing"
  exit 0
fi

# Push the branch.
push_log=$(mktemp)
if ! git push -u origin "$BRANCH" >"$push_log" 2>&1; then
  jq -cn --arg b "$BRANCH" --rawfile r "$push_log" \
    '{error: ("git push failed for " + $b), response: $r}'
  exit 1
fi

# Open the PR.
# gh has a --draft flag but no --ready (ready is the default), so we add
# --draft only when asked and omit it otherwise — mirroring the gitlab hook.
gh_args=(
  pr create
  --base "$BASE"
  --head "$BRANCH"
  --title "$TITLE"
  --body-file "$body_file"
)
if [[ "$DRAFT_FLAG" == "--draft" ]]; then
  gh_args+=(--draft)
fi
if [[ -n "$ASSIGNEE" ]]; then
  gh_args+=(--assignee "$ASSIGNEE")
fi

create_log=$(mktemp)
if ! gh "${gh_args[@]}" >"$create_log" 2>&1; then
  jq -cn --arg b "$BRANCH" --rawfile r "$create_log" \
    '{error: ("gh pr create failed for " + $b), response: $r}'
  exit 1
fi

# `gh pr create` prints the PR URL on success.
url=$(grep -Eo 'https?://[^[:space:]]+' "$create_log" | tail -n1)
if [[ -z "$url" ]]; then
  jq -cn --rawfile r "$create_log" '{error:"could not parse PR url from gh output", response: $r}'
  exit 1
fi
number="${url##*/}"

printf 'opened: forge=github url=%s number=%s\n' "$url" "$number"
