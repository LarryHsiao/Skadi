#!/bin/bash
# Usage: echo "MR description markdown" | celebrimbor-gitlab-mr.sh <branch> <base> <title> [--draft|--ready]
#   <branch>  local branch carrying the commits to ship
#   <base>    branch to target the MR at
#   <title>   one-line MR title
#   --draft   open as draft (default; glab uses Draft: prefix)
#   --ready   open as ready-for-review
# Pushes the branch to origin, then opens an MR via `glab`.
# On success prints one line: opened: forge=gitlab url=<mr-url> number=<n>
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.
# This hook does not handle credential resolution beyond what `glab` does on its own.

set -euo pipefail
export LC_ALL=C.UTF-8

BRANCH="${1:-}"
BASE="${2:-}"
TITLE="${3:-}"
DRAFT_FLAG="${4:---draft}"

if [[ -z "$BRANCH" || -z "$BASE" || -z "$TITLE" ]]; then
  echo '{"error":"usage: celebrimbor-gitlab-mr.sh <branch> <base> <title> [--draft|--ready] (body on stdin)"}'
  exit 1
fi

case "$DRAFT_FLAG" in
  --draft|--ready) ;;
  *)
    echo '{"error":"fourth arg must be --draft or --ready"}'
    exit 1
    ;;
esac

if ! command -v glab >/dev/null 2>&1; then
  echo '{"error":"glab CLI not found on PATH"}'
  exit 1
fi

if ! glab auth status >/dev/null 2>&1; then
  echo '{"error":"glab is not authenticated; run `glab auth login` first"}'
  exit 1
fi

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  jq -cn --arg b "$BRANCH" '{error: ("local branch not found: " + $b)}'
  exit 1
fi

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  jq -cn --arg b "$BASE" '{error: ("base branch not found locally: " + $b + "; fetch it first")}'
  exit 1
fi

# Body via stdin → tempfile, normalised to UTF-8.
body_file=$(mktemp)
trap 'rm -f "$body_file" "${push_log:-}" "${create_log:-}"' EXIT
cat > "$body_file"

if ! iconv -f UTF-8 -t UTF-8 "$body_file" >/dev/null 2>&1; then
  if iconv -f WINDOWS-1252 -t UTF-8 "$body_file" > "$body_file.utf8" 2>/dev/null; then
    mv "$body_file.utf8" "$body_file"
  else
    echo '{"error":"MR body is neither valid UTF-8 nor CP1252"}'
    exit 1
  fi
fi

# Push the branch.
push_log=$(mktemp)
if ! git push -u origin "$BRANCH" >"$push_log" 2>&1; then
  jq -cn --arg b "$BRANCH" --rawfile r "$push_log" \
    '{error: ("git push failed for " + $b), response: $r}'
  exit 1
fi

# Open the MR.
# glab's draft toggle is --draft (boolean); ready means we omit it.
glab_args=(
  mr create
  --source-branch "$BRANCH"
  --target-branch "$BASE"
  --title "$TITLE"
  --description "$(cat "$body_file")"
  --yes
)
if [[ "$DRAFT_FLAG" == "--draft" ]]; then
  glab_args+=(--draft)
fi

create_log=$(mktemp)
if ! glab "${glab_args[@]}" >"$create_log" 2>&1; then
  jq -cn --arg b "$BRANCH" --rawfile r "$create_log" \
    '{error: ("glab mr create failed for " + $b), response: $r}'
  exit 1
fi

# `glab mr create` prints the MR URL on success.
url=$(grep -Eo 'https?://[^[:space:]]+' "$create_log" | tail -n1)
if [[ -z "$url" ]]; then
  jq -cn --rawfile r "$create_log" '{error:"could not parse MR url from glab output", response: $r}'
  exit 1
fi
number="${url##*/}"

printf 'opened: forge=gitlab url=%s number=%s\n' "$url" "$number"
