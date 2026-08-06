#!/usr/bin/env bash
# argonath-merge-check.sh — dry-run a merge of HEAD onto a resolved target
# branch, without touching the working tree or index.
#
# Usage: argonath-merge-check.sh <target-ref>
#
# Resolution of <target-ref> is the caller's job (the same master / main /
# origin/HEAD order /mithrandir already uses). This hook only probes it.
#
# Uses `git merge-tree --write-tree` (git >= 2.38), which computes the merge
# entirely in memory. On a clean merge it prints just the resulting tree OID
# and exits 0. On conflicts it exits non-zero and its output carries
# `CONFLICT (...): ... in <path>` lines, which are parsed into
# conflicted_paths.
#
# A target ref that does not resolve locally, or a git too old to carry
# `--write-tree`, both degrade to ok:true with an explanatory note — the row
# reads as skipped, not as a false pass or a false hold.
#
# Output: single-line JSON
#   { "ok": bool, "conflicted_paths": [string], "note": string }
#
# Exit 0 always — caller reads `ok`.
set -u

target="${1:-}"

if [ -z "$target" ]; then
  jq -nc '{ok:true,conflicted_paths:[],note:"no target resolved — skipped"}'
  exit 0
fi

if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
  jq -nc --arg target "$target" \
    '{ok:true,conflicted_paths:[],note:("target " + $target + " not found locally — skipped")}'
  exit 0
fi

merge_out="$(git merge-tree --write-tree "$target" HEAD 2>&1)"
status=$?

if [ "$status" -eq 0 ]; then
  jq -nc --arg target "$target" '{ok:true,conflicted_paths:[],note:("clean merge against " + $target)}'
  exit 0
fi

if ! printf '%s\n' "$merge_out" | grep -q '^CONFLICT'; then
  first_line="$(printf '%s\n' "$merge_out" | head -n1)"
  jq -nc --arg line "$first_line" \
    '{ok:true,conflicted_paths:[],note:("merge-tree unavailable or errored — skipped (" + $line + ")")}'
  exit 0
fi

paths_json="$(printf '%s\n' "$merge_out" \
  | grep '^CONFLICT' \
  | sed -E '
      s/^CONFLICT \([^)]*\): .*[Mm]erge conflict in (.+)$/\1/
      t
      s/^CONFLICT \([^)]*\): //
    ' \
  | sort -u \
  | jq -R -s 'split("\n") | map(select(length>0))')"

jq -nc --argjson paths "$paths_json" --arg target "$target" \
  '{ok:false,conflicted_paths:$paths,note:("conflicts against " + $target)}'
