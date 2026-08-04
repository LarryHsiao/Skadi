#!/bin/bash
# Usage: durin-github-list.sh <scope>
# Lists open GitHub PRs in the *current* repo (cwd's origin remote) for the sweep.
#
#   <scope>:
#     mine -> --author @me
#     all  -> no author filter
#
# Emits a JSON array on stdout, one entry per PR:
#
#   [
#     {
#       "url": "https://github.com/owner/repo/pull/42",
#       "number": 42,
#       "title": "feat: add session summary hook",
#       "head": "feat-session-summary",
#       "base": "main"
#     },
#     ...
#   ]
#
# The sweeper fetches per-PR comment arrays via narvi-github-comments.sh to
# build the manifest — this list hook does not estimate counts, so the comment
# bookkeeping has one source of truth.
#
# On failure prints {"error":"..."} and exits non-zero.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

SCOPE="${1:-mine}"

if [[ "$SCOPE" != "mine" && "$SCOPE" != "all" ]]; then
  jq -cn --arg s "$SCOPE" '{error: ("scope must be `mine` or `all`, got: " + $s)}'
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

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo '{"error":"cwd is not inside a git repo"}'
  exit 1
fi

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$ORIGIN_URL" ]]; then
  echo '{"error":"no origin remote on current repo"}'
  exit 1
fi

repo_slug=""
if [[ "$ORIGIN_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  repo_slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
fi

if [[ -z "$repo_slug" ]]; then
  jq -cn --arg u "$ORIGIN_URL" '{error: ("origin is not a github remote: " + $u)}'
  exit 1
fi

raw_log=$(mktemp)
trap 'rm -f "$raw_log"' EXIT

# shellcheck disable=SC2054  # the commas belong to gh's --json field list,
# which is one argument; spaces here would make each field its own word.
args=( pr list --repo "$repo_slug" --state open --limit 100 --json url,number,title,body,headRefName,baseRefName )
if [[ "$SCOPE" == "mine" ]]; then
  args+=( --author "@me" )
fi

if ! gh "${args[@]}" >"$raw_log" 2>&1; then
  jq -cn --arg r "$repo_slug" --rawfile b "$raw_log" \
    '{error: ("gh pr list failed for " + $r), response: $b}'
  exit 1
fi

jq '
  map(select(
    ((.title // "") | test("\\[pending\\]"; "i") | not) and
    ((.body  // "") | test("pending";       "i") | not)
  ))
  | map({
      url: .url,
      number: .number,
      title: .title,
      head: .headRefName,
      base: .baseRefName
    })
' "$raw_log"
