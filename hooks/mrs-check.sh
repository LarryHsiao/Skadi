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
# Output: pipe-delimited lines "category|project|iid|title|web_url|isDraft|pipeline"
#   category: review | mine
#   pipeline: ok | processing | failed | cancelled | none
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
          (.project_id | tostring),
          (.iid | tostring),
          $kind,
          (.references.full | split("!") | .[0]),
          .title,
          .web_url,
          ((.draft // .work_in_progress // false) | tostring)
        ] | @tsv
      ' \
    | while IFS=$'\t' read -r pid iid cat proj title url draft; do
        status="$(glab api "projects/$pid/merge_requests/$iid" 2>/dev/null \
          | jq -r '
              .head_pipeline.status as $s |
              if   $s == null        then "none"
              elif $s == "skipped"   then "none"
              elif $s == "success"   then "ok"
              elif $s == "failed"    then "failed"
              elif $s == "canceled"  then "cancelled"
              else                        "processing"
              end
            ')"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$cat" "$proj" "$iid" "$title" "$url" "$draft" "$status"
      done
}

case "$mode" in
  review) query review ;;
  mine)   query mine ;;
  both)   query review; query mine ;;
esac
