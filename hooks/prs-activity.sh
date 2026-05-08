#!/usr/bin/env bash
# prs-activity.sh — list open PRs with unread GitHub notifications.
# Read-only (gh api /notifications).
#
# Usage:
#   prs-activity.sh
#
# Output: pipe-delimited lines "repo|number" for each PR with unread activity
# the user has participated in (mentioned, requested, assigned, commented).
#
# Empty stdout with exit 0  → no unread activity on any participated PR.
# Non-zero exit             → the API call failed (auth, missing scope, network).
#
# Requires the 'notifications' OAuth scope on gh's token. To grant it:
#   gh auth refresh -s notifications
set -uo pipefail

gh api '/notifications?participating=true&all=false&per_page=100' \
  | jq -r '
      .[]
      | select(.subject.type == "PullRequest")
      | (.repository.full_name) as $repo
      | (.subject.url | split("/") | .[-1]) as $num
      | "\($repo)|\($num)"
    '
