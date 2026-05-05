#!/bin/bash
# Usage:
#   lindir-gitlab-mr.sh <mr-url>          # prints JSON brief (default)
#   lindir-gitlab-mr.sh --diff <mr-url>   # prints raw unified diff to stdout
#
# JSON shape: {title, number, author, state, head, base, description, files:[{path,additions,deletions}]}
# On failure prints {"error":"...","response":"..."} and exits non-zero.
#
# Auth note: requires `glab auth login` to have been completed for the host.
# The --repo argument is built from the URL itself so self-hosted GitLab works
# without depending on glab's default host.

set -euo pipefail
export LC_ALL=C.UTF-8

MODE="json"
if [[ "${1:-}" == "--diff" ]]; then
  MODE="diff"
  shift
fi

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo '{"error":"usage: lindir-gitlab-mr.sh [--diff] <mr-url>"}'
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

# Parse group/project and MR iid from the URL.
# Pattern: https?://<host>/<group...>/-/merge_requests/<iid>
# The group portion may include subgroups (slashes), so the regex is greedy up to "/-/".
if [[ ! "$URL" =~ ^https?://[^/]+/(.+)/-/merge_requests/([0-9]+) ]]; then
  jq -cn --arg u "$URL" '{error: ("not a gitlab merge request URL: " + $u)}'
  exit 1
fi
IID="${BASH_REMATCH[2]}"
# Build the host-qualified repo URL so glab targets the right instance.
# Strips everything from "/-/merge_requests/..." onward, leaving "<scheme>://<host>/<group/project>".
REPO_URL="${URL%/-/merge_requests/*}"

# --diff mode: print raw unified diff and exit.
if [[ "$MODE" == "diff" ]]; then
  exec glab mr diff "$IID" --repo "$REPO_URL" --raw
fi

view_log=$(mktemp)
diff_log=$(mktemp)
trap 'rm -f "$view_log" "$diff_log"' EXIT

# `glab mr view --output=json` gives the structured fields we need.
if ! glab mr view "$IID" \
      --repo "$REPO_URL" \
      --output json \
      >"$view_log" 2>&1; then
  jq -cn --arg u "$URL" --rawfile r "$view_log" \
    '{error: ("glab mr view failed for " + $u), response: $r}'
  exit 1
fi

# `glab mr diff --raw` prints unified diff. We parse per-file additions/deletions
# from the diff text; counting + and - lines, ignoring the +++/--- headers.
if ! glab mr diff "$IID" \
      --repo "$REPO_URL" \
      --raw \
      >"$diff_log" 2>&1; then
  jq -cn --arg u "$URL" --rawfile r "$diff_log" \
    '{error: ("glab mr diff failed for " + $u), response: $r}'
  exit 1
fi

# Build a JSON array of {path,additions,deletions} from the diff.
files_json=$(awk '
  BEGIN { path=""; add=0; del=0; first=1; printf "[" }
  /^diff --git / {
    if (path != "") {
      if (!first) printf ",";
      first=0;
      printf "{\"path\":\"%s\",\"additions\":%d,\"deletions\":%d}", path, add, del;
    }
    # Path is the b/ side of the diff header.
    n = split($0, parts, " ");
    bpath = parts[n];
    sub(/^b\//, "", bpath);
    path = bpath;
    add = 0; del = 0;
    next;
  }
  /^\+\+\+ / { next }
  /^--- / { next }
  /^\+/ { add++; next }
  /^-/ { del++; next }
  END {
    if (path != "") {
      if (!first) printf ",";
      printf "{\"path\":\"%s\",\"additions\":%d,\"deletions\":%d}", path, add, del;
    }
    printf "]"
  }
' "$diff_log")

# Compose the final JSON. Field names from glab mr view --output=json:
# title, iid, author.username, state, source_branch, target_branch, description.
jq -n \
  --slurpfile view "$view_log" \
  --argjson files "$files_json" \
  '($view[0]) as $v
   | {
       title: ($v.title // ""),
       number: ($v.iid // 0),
       author: ($v.author.username // ""),
       state: ($v.state // ""),
       head: ($v.source_branch // ""),
       base: ($v.target_branch // ""),
       description: ($v.description // ""),
       files: $files
     }'
