#!/usr/bin/env bash
# prs-check.sh — list open PRs requiring attention.
# Read-only (gh search).
#
# Usage:
#   prs-check.sh              # both: review-requested + authored by me
#   prs-check.sh review       # only: review requested from me
#   prs-check.sh mine         # only: authored by me
#   prs-check.sh OWNER/REPO   # scope to a repo (both modes)
#
# Output: pipe-delimited lines "category|repo|number|title|url|isDraft"
#   category: review | mine
set -u

mode="both"
repo_arg=""

for arg in "$@"; do
  case "$arg" in
    review|mine|both) mode="$arg" ;;
    */*)              repo_arg="--repo $arg" ;;
    *)                echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

common='number,title,repository,url,isDraft'

fetch() {
  local kind="$1" flag
  case "$kind" in
    review) flag="--review-requested=@me" ;;
    mine)   flag="--author=@me" ;;
  esac
  # shellcheck disable=SC2086
  gh search prs --state=open $flag $repo_arg \
    --json "$common" --limit 50 2>/dev/null \
    | jq -r --arg kind "$kind" \
        '.[] | [$kind, .repository.nameWithOwner, (.number|tostring), .title, .url, (.isDraft|tostring)] | join("|")'
}

case "$mode" in
  review) fetch review ;;
  mine)   fetch mine ;;
  both)   fetch review; fetch mine ;;
esac
