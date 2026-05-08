#!/usr/bin/env bash
# mrs-activity.sh — list open MRs with pending GitLab todos.
# Read-only (glab api /todos).
#
# Usage:
#   mrs-activity.sh
#
# Output: pipe-delimited lines "project|iid" for each MR carrying a pending
# todo for the current user (mention, review request, comment thread).
#
# Empty stdout with exit 0  → no pending MR todos.
# Non-zero exit             → the API call failed (auth, scope, network).
#
# A todo is GitLab's own "owe-an-action" record; marking it done on
# gitlab.com mutates the source state, so this respects what the user has
# already read in the browser.
set -uo pipefail

if [ -z "${GITLAB_HOST:-}" ]; then
  GITLAB_HOST="$(glab auth status 2>&1 | grep -oE 'Logged in to [^ ]+' | awk '{print $4; exit}')"
fi
export GITLAB_HOST

glab api '/todos?state=pending&per_page=100' \
  | jq -r '
      .[]
      | select(.target_type == "MergeRequest")
      | (.project.path_with_namespace) as $proj
      | (.target.iid | tostring) as $iid
      | "\($proj)|\($iid)"
    '
