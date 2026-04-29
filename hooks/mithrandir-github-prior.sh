#!/bin/bash
# Usage: mithrandir-github-prior.sh <pr-url>
# Finds the most recent Mithrandir `comment`-verb post on the PR (matched by
# the blockquote header signature) and prints its html_url on stdout.
# Prints nothing on stdout if no prior counsel is found (still exits 0).
# On forge or auth error: prints {"error":"..."} and exits non-zero.
#
# Strict signature: a body whose first line is
#   > <gauge> **(Merge|Hold|Refuse)** ...
# where <gauge> is three characters from {U+25B0 ▰, U+25B1 ▱}.
# Bless posts (`All resolve` / `Partial okay`) are deliberately skipped — the
# bless verb anchors to the original verdict, not to its own echoes.
#
# Auth note: requires `gh auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: mithrandir-github-prior.sh <pr-url>"}'
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

comments_log=$(mktemp)
trap 'rm -f "$comments_log"' EXIT

if ! gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
      >"$comments_log" 2>&1; then
  cat "$comments_log" >&2
  exit 1
fi

jq -nr --slurpfile pages "$comments_log" '
  ($pages | add)
  | map(select(.body | test("^> [▰▱]{3} \\*\\*(Merge|Hold|Refuse)\\*\\* ")))
  | sort_by(.created_at)
  | reverse
  | first
  | (.html_url // empty)
'
