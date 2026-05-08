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
# Output: pipe-delimited lines "category|repo|number|title|url|isDraft|pipeline"
#   category: review | mine
#   pipeline: ok | processing | failed | cancelled | none
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
        '.[] | [.repository.nameWithOwner, (.number|tostring), $kind, .title, .url, (.isDraft|tostring)] | @tsv' \
    | while IFS=$'\t' read -r repo num cat title url draft; do
        status="$(gh pr view "$num" --repo "$repo" --json statusCheckRollup 2>/dev/null \
          | jq -r '
              [.statusCheckRollup[]? | (.conclusion // .status // "PENDING")] as $cs |
              if   ($cs | length) == 0 then "none"
              elif ($cs | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")) then "failed"
              elif ($cs | all(. == "CANCELLED")) then "cancelled"
              elif ($cs | any(. == "CANCELLED")) then "failed"
              elif ($cs | any(. == "IN_PROGRESS" or . == "QUEUED" or . == "PENDING" or . == "WAITING" or . == "REQUESTED")) then "processing"
              else "ok"
              end
            ')"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$cat" "$repo" "$num" "$title" "$url" "$draft" "$status"
      done
}

case "$mode" in
  review) fetch review ;;
  mine)   fetch mine ;;
  both)   fetch review; fetch mine ;;
esac
