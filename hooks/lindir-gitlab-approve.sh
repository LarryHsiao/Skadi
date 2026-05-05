#!/bin/bash
# Usage:
#   lindir-gitlab-approve.sh --prompt <mr-url>   # print {title,head,base} JSON for the confirm prompt
#   lindir-gitlab-approve.sh <mr-url>            # submit an approving review
# On success prints: approved: forge=gitlab url=<url> number=<iid>
# On failure surfaces the forge's error verbatim and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

MODE="approve"
if [[ "${1:-}" == "--prompt" ]]; then
  MODE="prompt"
  shift
fi

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: lindir-gitlab-approve.sh [--prompt] <mr-url>"}'
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

if [[ "$MODE" == "prompt" ]]; then
  view_log=$(mktemp)
  trap 'rm -f "$view_log"' EXIT
  if ! glab mr view "$IID" \
        --repo "$GROUP_PROJECT" \
        --output json \
        >"$view_log" 2>&1; then
    # Surface the forge error verbatim.
    cat "$view_log" >&2
    exit 1
  fi
  jq -c '{title: (.title // ""), head: (.source_branch // ""), base: (.target_branch // "")}' < "$view_log"
  exit 0
fi

# Approve mode — call `glab mr approve`.
approve_log=$(mktemp)
trap 'rm -f "$approve_log"' EXIT
if ! glab mr approve "$IID" \
      --repo "$GROUP_PROJECT" \
      >"$approve_log" 2>&1; then
  # Surface the forge's error verbatim.
  cat "$approve_log" >&2
  exit 1
fi

printf 'approved: forge=gitlab url=%s number=%s\n' "$URL" "$IID"
