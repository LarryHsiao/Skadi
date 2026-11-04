#!/bin/bash
# Usage: echo "comment body markdown" | mithrandir-gitlab-comment.sh <mr-url>
# Posts the body (read from stdin) as a note on the MR.
# On success prints: commented: forge=gitlab url=<url> number=<iid>
# On failure surfaces the forge's error verbatim and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: mithrandir-gitlab-comment.sh <mr-url> (body on stdin)"}'
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

body_file=$(mktemp)
trap 'rm -f "$body_file" "${note_log:-}"' EXIT
cat > "$body_file"

if [[ ! -s "$body_file" ]]; then
  echo '{"error":"comment body is empty"}'
  exit 1
fi

"$(dirname "$0")/body-to-utf8.sh" "$body_file" || exit 1

BODY=$(cat "$body_file")

note_log=$(mktemp)
if ! glab mr note "$IID" \
      --repo "$GROUP_PROJECT" \
      --message "$BODY" \
      >"$note_log" 2>&1; then
  cat "$note_log" >&2
  exit 1
fi

printf 'commented: forge=gitlab url=%s number=%s\n' "$URL" "$IID"
