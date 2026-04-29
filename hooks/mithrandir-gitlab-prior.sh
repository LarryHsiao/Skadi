#!/bin/bash
# Usage: mithrandir-gitlab-prior.sh <mr-url>
# Finds the most recent Mithrandir `comment`-verb discussion on the MR (matched
# by the blockquote header signature on the discussion's first note) and prints
# JSON {"discussion_id","note_id","note_url"} on stdout.
# Prints nothing on stdout if no prior counsel is found (still exits 0).
# On forge or auth error: prints {"error":"..."} and exits non-zero.
#
# Strict signature: first note's body line one is
#   > <gauge> **(Merge|Hold|Refuse)** ...
# where <gauge> is three characters from {U+25B0 ▰, U+25B1 ▱}.
# Bless posts (`All resolve` / `Partial okay`) are deliberately skipped — the
# bless verb anchors to the original verdict, not to its own echoes.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: mithrandir-gitlab-prior.sh <mr-url>"}'
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

discussions_log=$(mktemp)
trap 'rm -f "$discussions_log"' EXIT

if ! glab api --paginate "projects/$ENCODED/merge_requests/$IID/discussions" \
      >"$discussions_log" 2>&1; then
  cat "$discussions_log" >&2
  exit 1
fi

jq -nc \
  --slurpfile pages "$discussions_log" \
  --arg url "$URL" \
  '
  ($pages | add) as $all
  | $all
  | map(select((.notes | length) > 0))
  | map(select(.notes[0].system == false))
  | map(select(.notes[0].body | test("^> [▰▱]{3} \\*\\*(Merge|Hold|Refuse)\\*\\* ")))
  | sort_by(.notes[0].created_at)
  | reverse
  | first
  | if . == null then empty
    else
      {
        discussion_id: .id,
        note_id: .notes[0].id,
        note_url: ($url + "#note_" + (.notes[0].id | tostring))
      }
    end
  '
