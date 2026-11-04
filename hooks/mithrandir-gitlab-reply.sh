#!/bin/bash
# Usage: echo "comment body markdown" | mithrandir-gitlab-reply.sh <mr-url> <discussion-id>
# Posts the body (read from stdin) as a reply note inside the named discussion
# on the MR, so it threads under the original comment rather than landing
# top-level on the MR.
# On success prints: replied: forge=gitlab url=<url> number=<iid> discussion=<id>
# On failure surfaces the forge's error verbatim and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
DISCUSSION_ID="${2:-}"
if [[ -z "$URL" || -z "$DISCUSSION_ID" ]]; then
  echo '{"error":"usage: mithrandir-gitlab-reply.sh <mr-url> <discussion-id> (body on stdin)"}'
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

# Pin the host so glab routes self-hosted instances correctly.
if [[ "$URL" =~ ^https?://([^/]+) ]]; then
  export GITLAB_HOST="${BASH_REMATCH[1]}"
fi

body_file=$(mktemp)
payload_file=$(mktemp)
post_log=$(mktemp)
trap 'rm -f "$body_file" "$payload_file" "$post_log"' EXIT
cat > "$body_file"

if [[ ! -s "$body_file" ]]; then
  echo '{"error":"comment body is empty"}'
  exit 1
fi

"$(dirname "$0")/body-to-utf8.sh" "$body_file" || exit 1

# Build the JSON payload via jq so multi-line markdown is escaped safely.
jq -Rs '{body: .}' < "$body_file" > "$payload_file"

if ! glab api --input "$payload_file" -X POST \
      "projects/$ENCODED/merge_requests/$IID/discussions/$DISCUSSION_ID/notes" \
      >"$post_log" 2>&1; then
  cat "$post_log" >&2
  exit 1
fi

printf 'replied: forge=gitlab url=%s number=%s discussion=%s\n' "$URL" "$IID" "$DISCUSSION_ID"
