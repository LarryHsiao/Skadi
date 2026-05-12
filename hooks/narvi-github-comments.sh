#!/bin/bash
# Usage: narvi-github-comments.sh <pr-url>
# Fetches every comment on a GitHub PR that Narvi should consider, via one
# `gh api graphql` call. Emits a single JSON array on stdout. Each element is
# one comment-thread (or one overview comment) tagged with its kind:
#
#   [
#     {
#       "kind": "inline",
#       "thread_id": "PRT_kwDO...",
#       "path": "src/foo.dart",
#       "line": 42,
#       "diff_side": "RIGHT",
#       "diff_hunk": "@@ -40,3 +40,4 @@ ...",
#       "comments": [ { "author": "alice", "body": "...", "url": "...", "created_at": "..." } ]
#     },
#     {
#       "kind": "overview",
#       "thread_id": "IC_kwDO...",
#       "path": "",
#       "line": 0,
#       "diff_side": "",
#       "diff_hunk": "",
#       "comments": [ { "author": "alice", "body": "<top-level body>", "url": "...", "created_at": "..." } ]
#     }
#   ]
#
# What counts:
#   - inline: review threads whose `isResolved` is false, with at least one comment.
#   - overview: issue-comments (the conversation-tab comments) with a non-empty body.
#   - overview: review bodies (Approve / Request-changes / Comment) with a non-empty body.
#     Reviews with empty body are dropped — their inline comments already appear
#     under reviewThreads, and an empty review body carries no overview ask.
#
# Order: stable per-source; the skill body sorts by created_at across the array.
#
# On failure prints {"error":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: narvi-github-comments.sh <pr-url>"}'
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo '{"error":"gh CLI not found on PATH"}'
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo '{"error":"gh is not authenticated; run `gh auth login` first"}'
  exit 1
fi

if [[ ! "$URL" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  jq -cn --arg u "$URL" '{error: ("not a github pull request URL: " + $u)}'
  exit 1
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"

query='query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          path
          line
          diffSide
          comments(first: 100) {
            nodes {
              author { login }
              body
              diffHunk
              url
              createdAt
            }
          }
        }
      }
      comments(first: 100) {
        nodes {
          id
          author { login }
          body
          url
          createdAt
        }
      }
      reviews(first: 100) {
        nodes {
          id
          state
          author { login }
          body
          url
          createdAt
        }
      }
    }
  }
}'

raw_log=$(mktemp)
trap 'rm -f "$raw_log"' EXIT

if ! gh api graphql \
      -F owner="$OWNER" \
      -F repo="$REPO" \
      -F number="$NUMBER" \
      -f query="$query" \
      >"$raw_log" 2>&1; then
  jq -cn --arg u "$URL" --rawfile r "$raw_log" \
    '{error: ("gh api graphql failed for " + $u), response: $r}'
  exit 1
fi

jq '
  .data.repository.pullRequest as $pr
  | (
      ($pr.reviewThreads.nodes
        | map(select(.isResolved == false))
        | map(select((.comments.nodes | length) > 0))
        | map({
            kind: "inline",
            thread_id: .id,
            path: (.path // ""),
            line: (.line // 0),
            diff_side: (.diffSide // ""),
            diff_hunk: ((.comments.nodes[0].diffHunk) // ""),
            comments: (.comments.nodes | map({
              author: ((.author.login) // ""),
              body: (.body // ""),
              url: (.url // ""),
              created_at: (.createdAt // "")
            }))
          })
      )
      +
      ($pr.comments.nodes
        | map(select((.body // "") != ""))
        | map({
            kind: "overview",
            thread_id: .id,
            path: "",
            line: 0,
            diff_side: "",
            diff_hunk: "",
            comments: [{
              author: ((.author.login) // ""),
              body: (.body // ""),
              url: (.url // ""),
              created_at: (.createdAt // "")
            }]
          })
      )
      +
      ($pr.reviews.nodes
        | map(select((.body // "") != ""))
        | map({
            kind: "overview",
            thread_id: .id,
            path: "",
            line: 0,
            diff_side: "",
            diff_hunk: "",
            comments: [{
              author: ((.author.login) // ""),
              body: (.body // ""),
              url: (.url // ""),
              created_at: (.createdAt // "")
            }]
          })
      )
    )
' "$raw_log"
