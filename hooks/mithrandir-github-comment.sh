#!/bin/bash
# Usage: echo "comment body markdown" | mithrandir-github-comment.sh <pr-url>
# Posts the body (read from stdin) as a comment on the PR.
# On success prints: commented: forge=github url=<url> number=<n>
# On failure surfaces the forge's error verbatim and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: mithrandir-github-comment.sh <pr-url> (body on stdin)"}'
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
trap 'rm -f "$body_file" "${comment_log:-}"' EXIT
cat > "$body_file"

if [[ ! -s "$body_file" ]]; then
  echo '{"error":"comment body is empty"}'
  exit 1
fi

if ! iconv -f UTF-8 -t UTF-8 "$body_file" >/dev/null 2>&1; then
  if iconv -f WINDOWS-1252 -t UTF-8 "$body_file" > "$body_file.utf8" 2>/dev/null; then
    mv "$body_file.utf8" "$body_file"
  else
    echo '{"error":"comment body is neither valid UTF-8 nor CP1252"}'
    exit 1
  fi
fi

comment_log=$(mktemp)
if ! gh pr comment "$NUMBER" \
      --repo "$OWNER/$REPO" \
      --body-file "$body_file" \
      >"$comment_log" 2>&1; then
  cat "$comment_log" >&2
  exit 1
fi

printf 'commented: forge=github url=%s number=%s\n' "$URL" "$NUMBER"
