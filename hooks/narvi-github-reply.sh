#!/bin/bash
# Usage: narvi-github-reply.sh <pr-url> <kind> <thread-id>
# Body on stdin. <kind> is `inline` or `overview`.
#
# For kind=inline:
#   `thread-id` is a PullRequestReviewThread node ID (PRT_...). Posts a reply
#   via GraphQL `addPullRequestReviewThreadReply` so the note threads under
#   the original review comment on the PR.
#
# For kind=overview:
#   `thread-id` is unused (the skill body still passes it for uniformity, but
#   GitHub has no reply-to primitive for issue-comments or review bodies).
#   Posts a fresh issue-comment via `gh pr comment` with the body verbatim;
#   the skill body is expected to include a "(Reply to <url>)" footer in the
#   body for visual linkage.
#
# On success prints: replied: forge=github kind=<inline|overview> url=<reply-url>
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
KIND="${2:-}"
THREAD_ID="${3:-}"

if [[ -z "$URL" || -z "$KIND" ]]; then
  echo '{"error":"usage: narvi-github-reply.sh <pr-url> <kind> <thread-id> (body on stdin)"}'
  exit 1
fi

if [[ "$KIND" != "inline" && "$KIND" != "overview" ]]; then
  jq -cn --arg k "$KIND" '{error: ("unknown kind: " + $k + " — expected inline or overview")}'
  exit 1
fi

if [[ "$KIND" == "inline" && -z "$THREAD_ID" ]]; then
  echo '{"error":"thread-id is required for kind=inline"}'
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

body_file=$(mktemp)
resp_log=$(mktemp)
trap 'rm -f "$body_file" "$resp_log"' EXIT
cat > "$body_file"

if [[ ! -s "$body_file" ]]; then
  echo '{"error":"reply body is empty"}'
  exit 1
fi

if [[ "$KIND" == "inline" ]]; then
  query='mutation($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input: {
      pullRequestReviewThreadId: $threadId,
      body: $body
    }) {
      comment { url }
    }
  }'

  # Build the GraphQL request body as JSON so the multi-line/special-char body
  # is encoded safely. gh api graphql --input - reads the JSON envelope.
  if ! jq -nc \
        --arg query "$query" \
        --arg threadId "$THREAD_ID" \
        --rawfile body "$body_file" \
        '{query: $query, variables: {threadId: $threadId, body: $body}}' \
       | gh api graphql --input - >"$resp_log" 2>&1; then
    jq -cn --rawfile r "$resp_log" '{error: "gh api graphql addPullRequestReviewThreadReply failed", response: $r}'
    exit 1
  fi

  reply_url=$(jq -r '.data.addPullRequestReviewThreadReply.comment.url // empty' "$resp_log")
  if [[ -z "$reply_url" ]]; then
    jq -cn --rawfile r "$resp_log" '{error: "no reply url in response", response: $r}'
    exit 1
  fi
  printf 'replied: forge=github kind=inline url=%s\n' "$reply_url"
  exit 0
fi

# kind=overview — post a fresh issue-comment.
if ! gh pr comment "$NUMBER" \
      --repo "$OWNER/$REPO" \
      --body-file "$body_file" \
      >"$resp_log" 2>&1; then
  cat "$resp_log" >&2
  exit 1
fi

# `gh pr comment` prints the comment URL on stdout. Tail it.
reply_url=$(grep -Eo 'https?://[^ ]+' "$resp_log" | head -n1)
printf 'replied: forge=github kind=overview url=%s\n' "${reply_url:-<unknown>}"
