#!/bin/bash
# Usage: narvi-gitlab-comments.sh <mr-url>
# Fetches every discussion on a GitLab MR that Narvi should consider, via
# `glab api`. Emits a single JSON array on stdout. Each element is one
# discussion-thread (or one overview note) tagged with its kind:
#
#   [
#     {
#       "kind": "inline",
#       "thread_id": "abc123...",
#       "path": "lib/foo.dart",
#       "line": 42,
#       "diff_side": "RIGHT",
#       "diff_hunk": "",
#       "comments": [ { "author": "alice", "body": "...", "url": "...", "created_at": "..." } ]
#     },
#     {
#       "kind": "overview",
#       "thread_id": "def456...",
#       "path": "",
#       "line": 0,
#       "diff_side": "",
#       "diff_hunk": "",
#       "comments": [ { "author": "alice", "body": "...", "url": "...", "created_at": "..." } ]
#     }
#   ]
#
# What counts:
#   - inline: discussions whose first note is non-system, resolvable=true,
#     resolved=false, and carries a `position` (diff-anchored).
#   - overview: discussions whose first note is non-system, has no `position`
#     (general MR-level comment), and whose body is non-empty. Generic MR
#     comments are not resolvable in GitLab's data model — de-duplication is
#     the skill body's job, via the commit-footer trail.
#
# `diff_side` is `RIGHT` when the inline note anchors to `new_line`, `LEFT`
# when only `old_line` is set. `diff_hunk` is left empty — GitLab does not
# expose a preformatted hunk on the position object.
#
# On failure prints {"error":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.

set -euo pipefail
export LC_ALL=C.UTF-8

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: narvi-gitlab-comments.sh <mr-url>"}'
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

jq -n \
  --slurpfile pages "$discussions_log" \
  --arg url "$URL" \
  '
  ($pages | add) as $all
  | (
      ($all
        | map(select((.notes | length) > 0))
        | map(select(.notes[0].system == false))
        | map(select(.notes[0].resolvable == true))
        | map(select(.notes[0].resolved == false))
        | map(select(.notes[0].position != null))
        | map({
            kind: "inline",
            thread_id: .id,
            path: ((.notes[0].position.new_path) // (.notes[0].position.old_path) // ""),
            line: ((.notes[0].position.new_line) // (.notes[0].position.old_line) // 0),
            diff_side: (if (.notes[0].position.new_line != null) then "RIGHT" else "LEFT" end),
            diff_hunk: "",
            comments: (.notes | map({
              author: ((.author.username) // ""),
              body: (.body // ""),
              url: ($url + "#note_" + (.id | tostring)),
              created_at: (.created_at // "")
            }))
          })
      )
      +
      ($all
        | map(select((.notes | length) > 0))
        | map(select(.notes[0].system == false))
        | map(select(.notes[0].position == null))
        | map(select((.notes[0].body // "") != ""))
        | map({
            kind: "overview",
            thread_id: .id,
            path: "",
            line: 0,
            diff_side: "",
            diff_hunk: "",
            comments: (.notes | map({
              author: ((.author.username) // ""),
              body: (.body // ""),
              url: ($url + "#note_" + (.id | tostring)),
              created_at: (.created_at // "")
            }))
          })
      )
    )
  '
