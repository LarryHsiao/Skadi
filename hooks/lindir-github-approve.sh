#!/bin/bash
# Usage:
#   lindir-github-approve.sh --prompt <pr-url>   # print {title,head,base} JSON for the confirm prompt
#   lindir-github-approve.sh <pr-url>            # submit an approving review
# On success prints: approved: forge=github url=<url> number=<n>
# On failure surfaces the forge's error verbatim and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

MODE="approve"
if [[ "${1:-}" == "--prompt" ]]; then
  MODE="prompt"
  shift
fi

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: lindir-github-approve.sh [--prompt] <pr-url>"}'
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

if [[ "$MODE" == "prompt" ]]; then
  view_log=$(mktemp)
  trap 'rm -f "$view_log"' EXIT
  if ! gh pr view "$NUMBER" \
        --repo "$OWNER/$REPO" \
        --json title,headRefName,baseRefName \
        >"$view_log" 2>&1; then
    # Surface the forge error verbatim.
    cat "$view_log" >&2
    exit 1
  fi
  jq -c '{title: (.title // ""), head: (.headRefName // ""), base: (.baseRefName // "")}' < "$view_log"
  exit 0
fi

# Approve mode — call `gh pr review --approve`.
review_log=$(mktemp)
trap 'rm -f "$review_log"' EXIT
if ! gh pr review "$NUMBER" \
      --repo "$OWNER/$REPO" \
      --approve \
      >"$review_log" 2>&1; then
  # Surface the forge's error verbatim.
  cat "$review_log" >&2
  exit 1
fi

printf 'approved: forge=github url=%s number=%s\n' "$URL" "$NUMBER"
