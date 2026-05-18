#!/bin/bash
# Usage: durin-gitlab-list.sh <scope>
# Lists open GitLab MRs in the *current* repo (cwd's origin remote) for the sweep.
#
#   <scope>:
#     mine -> mine only (assignee or author = current user)
#     all  -> every open MR in the project
#
# Emits a JSON array on stdout, one entry per MR:
#
#   [
#     {
#       "url": "https://gitlab.com/group/project/-/merge_requests/42",
#       "number": 42,
#       "title": "feat: add session summary hook",
#       "head": "feat-session-summary",
#       "base": "main"
#     },
#     ...
#   ]
#
# The sweeper fetches per-MR comment arrays via narvi-gitlab-comments.sh to
# build the manifest — this list hook does not estimate counts, so the comment
# bookkeeping has one source of truth.
#
# On failure prints {"error":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

SCOPE="${1:-mine}"

if [[ "$SCOPE" != "mine" && "$SCOPE" != "all" ]]; then
  jq -cn --arg s "$SCOPE" '{error: ("scope must be `mine` or `all`, got: " + $s)}'
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

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo '{"error":"cwd is not inside a git repo"}'
  exit 1
fi

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$ORIGIN_URL" ]]; then
  echo '{"error":"no origin remote on current repo"}'
  exit 1
fi

project_path=""
gl_host=""
if [[ "$ORIGIN_URL" =~ ^git@([^:]+):(.+?)(\.git)?$ ]]; then
  gl_host="${BASH_REMATCH[1]}"
  project_path="${BASH_REMATCH[2]}"
  project_path="${project_path%.git}"
elif [[ "$ORIGIN_URL" =~ ^https?://([^/]+)/(.+?)(\.git)?$ ]]; then
  gl_host="${BASH_REMATCH[1]}"
  project_path="${BASH_REMATCH[2]}"
  project_path="${project_path%.git}"
fi

if [[ -z "$project_path" || -z "$gl_host" ]]; then
  jq -cn --arg u "$ORIGIN_URL" '{error: ("could not parse gitlab origin: " + $u)}'
  exit 1
fi

export GITLAB_HOST="$gl_host"
ENCODED="${project_path//\//%2F}"

raw_log=$(mktemp)
trap 'rm -f "$raw_log"' EXIT

api_args=( "projects/$ENCODED/merge_requests?state=opened&per_page=100" )
if [[ "$SCOPE" == "mine" ]]; then
  api_args=( "projects/$ENCODED/merge_requests?state=opened&scope=created_by_me&per_page=100" )
fi

if ! glab api --paginate "${api_args[@]}" >"$raw_log" 2>&1; then
  jq -cn --arg p "$project_path" --rawfile b "$raw_log" \
    '{error: ("glab api merge_requests failed for " + $p), response: $b}'
  exit 1
fi

jq -s 'add // []
  | map(select(
      ((.title       // "") | test("\\[pending\\]"; "i") | not) and
      ((.description // "") | test("pending";       "i") | not)
    ))
  | map({
      url: .web_url,
      number: .iid,
      title: .title,
      head: .source_branch,
      base: .target_branch
    })' "$raw_log"
