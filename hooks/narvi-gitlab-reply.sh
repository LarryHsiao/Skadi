#!/bin/bash
# Usage: narvi-gitlab-reply.sh <mr-url> <discussion-id>
# Body on stdin.
#
# Posts a reply to a GitLab MR discussion via
#   POST /projects/:id/merge_requests/:iid/discussions/:discussion_id/notes
# Works uniformly for inline (diff-positioned) and overview (non-positioned)
# discussions — the discussions endpoint handles both shapes.
#
# On success prints: replied: forge=gitlab url=<reply-url>
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
DISCUSSION_ID="${2:-}"

if [[ -z "$URL" || -z "$DISCUSSION_ID" ]]; then
  echo '{"error":"usage: narvi-gitlab-reply.sh <mr-url> <discussion-id> (body on stdin)"}'
  exit 1
fi

if ! command -v glab >/dev/null 2>&1; then
  echo '{"error":"glab CLI not found on PATH"}'
  exit 1
fi

if ! glab auth status >/dev/null 2>&1; then
  echo '{"error":"glab is not authenticated; run `glab auth login` first"}'
  exit 1
fi

if [[ ! "$URL" =~ ^https?://[^/]+/(.+)/-/merge_requests/([0-9]+) ]]; then
  jq -cn --arg u "$URL" '{error: ("not a gitlab merge request URL: " + $u)}'
  exit 1
fi
GROUP_PROJECT="${BASH_REMATCH[1]}"
IID="${BASH_REMATCH[2]}"
ENCODED="${GROUP_PROJECT//\//%2F}"

if [[ "$URL" =~ ^https?://([^/]+) ]]; then
  export GITLAB_HOST="${BASH_REMATCH[1]}"
fi

body_file=$(mktemp)
resp_log=$(mktemp)
trap 'rm -f "$body_file" "$resp_log"' EXIT
cat > "$body_file"

if [[ ! -s "$body_file" ]]; then
  echo '{"error":"reply body is empty"}'
  exit 1
fi

if ! glab api \
      "projects/$ENCODED/merge_requests/$IID/discussions/$DISCUSSION_ID/notes" \
      --method POST \
      -f "body=$(cat "$body_file")" \
      >"$resp_log" 2>&1; then
  jq -cn --rawfile r "$resp_log" '{error: "glab api discussions notes POST failed", response: $r}'
  exit 1
fi

# GitLab returns the created note as JSON; compose the reply URL from the MR
# URL and the note ID since the API does not return a forge-side URL.
note_id=$(jq -r '.id // empty' "$resp_log")
if [[ -z "$note_id" ]]; then
  jq -cn --rawfile r "$resp_log" '{error: "no note id in response", response: $r}'
  exit 1
fi
printf 'replied: forge=gitlab url=%s#note_%s\n' "$URL" "$note_id"
