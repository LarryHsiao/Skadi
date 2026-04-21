#!/usr/bin/env bash
# mrs-check.sh — list open GitLab merge requests requiring attention.
# Read-only (glab api).
#
# Usage:
#   mrs-check.sh                   # both: reviewer + author, global scope
#   mrs-check.sh review            # only reviewer=@me
#   mrs-check.sh mine              # only author=@me
#   mrs-check.sh GROUP/PROJECT     # scope to a project (both modes)
#
# Output: pipe-delimited lines "category|project|iid|title|web_url|isDraft"
#   category: review | mine
set -u

mode="both"
repo=""

for arg in "$@"; do
  case "$arg" in
    review|mine|both) mode="$arg" ;;
    */*)              repo="$arg" ;;
    *)                echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ -z "${GITLAB_HOST:-}" ]; then
  GITLAB_HOST="$(glab auth status 2>&1 | grep -oE 'Logged in to [^ ]+' | awk '{print $4; exit}')"
fi
export GITLAB_HOST

me="$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null)"
if [ -z "$me" ]; then
  echo "glab auth failed — run: glab auth login" >&2
  exit 1
fi

url_encode() { jq -rn --arg s "$1" '$s | @uri'; }

query() {
  local kind="$1" path param
  case "$kind" in
    review) param="reviewer_username=$me" ;;
    mine)   param="author_username=$me" ;;
  esac
  if [ -n "$repo" ]; then
    path="projects/$(url_encode "$repo")/merge_requests?state=opened&$param&per_page=50"
  else
    path="merge_requests?scope=all&state=opened&$param&per_page=50"
  fi
  glab api "$path" 2>/dev/null \
    | jq -r --arg kind "$kind" '
        .[] | [
          $kind,
          (.references.full | split("!") | .[0]),
          (.iid | tostring),
          .title,
          .web_url,
          ((.draft // .work_in_progress // false) | tostring)
        ] | join("|")
      '
}

case "$mode" in
  review) query review ;;
  mine)   query mine ;;
  both)   query review; query mine ;;
esac
