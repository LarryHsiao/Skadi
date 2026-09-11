#!/usr/bin/env bash
# argonath-drift.sh — probe whether merging a target branch risks a *semantic*
# conflict, without merging anything.
#
# Usage: argonath-drift.sh <target-ref>
#
# Resolution of <target-ref> is the caller's job (the same master / main /
# origin/HEAD order /mithrandir and argonath-merge-check.sh already use). This
# hook only probes it.
#
# argonath-merge-check.sh answers "do the two sides collide textually?" — it
# reads hunks. A merge can be textually clean and still break: you swap the test
# framework while the target adds tests in the old one, you bump a dependency
# while the target adds code against the old API, both sides add a migration
# bearing the same version. Neither side touched the other's lines, so
# merge-tree sees nothing.
#
# The probe is two-layered, cheapest first:
#   1. Has the target moved at all since the branch point? A target standing
#      still carries no risk — there is nothing new to collide with. This alone
#      settles most runs for the cost of one rev-list.
#   2. If it has moved, do either side's changes land on a surface where a
#      silent collision is known to hide? Three kinds, and no more — a noisy
#      probe is one nobody reads:
#        dependency  — a manifest or lockfile, either side
#        test-config — a test-runner config, either side
#        migration   — a migrations directory, *both* sides (a version
#                      collision needs two)
#
# The probe never merges, never checks out, never writes. It reads refs and
# name-only diffs.
#
# Output: single-line JSON
#   { "ok": bool, "moved": int,
#     "signals": [ { "kind": string, "path": string, "side": string } ],
#     "note": string }
#
# `ok` is false when a signal fired — a *risk*, not a proven failure. The caller
# renders it advisory; it never holds a verdict on its own.
# `side` is one of: branch, target, both.
#
# A target that does not resolve, or histories with no common ancestor, degrade
# to ok:true with an explanatory note — the row reads as skipped, not as a false
# pass or a false warning.
#
# Exit 0 always — caller reads `ok`.
set -u

DEPENDENCY_RE='(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|pubspec\.yaml|pubspec\.lock|Cargo\.toml|Cargo\.lock|go\.mod|go\.sum|requirements\.txt|pyproject\.toml)$'
TEST_CONFIG_RE='(^|/)(jest\.config\.[A-Za-z]+|vitest\.config\.[A-Za-z]+|analysis_options\.yaml|pytest\.ini|tox\.ini|karma\.conf\.[A-Za-z]+|playwright\.config\.[A-Za-z]+|\.mocharc\.[A-Za-z]+|phpunit\.xml)$'
MIGRATION_RE='(^|/)(migrations?|migrate)/'

skipped() {
  jq -nc --arg note "$1" '{ok:true,moved:0,signals:[],note:$note}'
  exit 0
}

target="${1:-}"

[ -z "$target" ] && skipped "no target resolved — skipped"

if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
  skipped "target $target not found locally — skipped"
fi

base="$(git merge-base HEAD "$target" 2>/dev/null || true)"
[ -z "$base" ] && skipped "no common ancestor with $target — skipped"

moved="$(git rev-list --count "$base..$target" 2>/dev/null || echo 0)"

if [ "$moved" -eq 0 ]; then
  jq -nc --arg target "$target" \
    '{ok:true,moved:0,signals:[],note:("target " + $target + " unmoved since branch point")}'
  exit 0
fi

branch_files="$(git diff --name-only "$base..HEAD" 2>/dev/null || true)"
target_files="$(git diff --name-only "$base..$target" 2>/dev/null || true)"

# Emit one JSON object per matched path. `sides_required` is `either-side` when
# one side touching the surface is already a risk, or `both-sides` for the kinds
# whose risk only exists when each side brought its own change.
emit_signals() {
  local kind="$1" pattern="$2" sides_required="$3"
  local on_branch on_target matched path side

  on_branch="$(printf '%s\n' "$branch_files" | grep -E "$pattern" || true)"
  on_target="$(printf '%s\n' "$target_files" | grep -E "$pattern" || true)"

  if [ "$sides_required" = "both-sides" ] && { [ -z "$on_branch" ] || [ -z "$on_target" ]; }; then
    return
  fi

  matched="$(printf '%s\n%s\n' "$on_branch" "$on_target" | grep -v '^$' | sort -u)"
  [ -z "$matched" ] && return

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if printf '%s\n' "$on_branch" | grep -qxF "$path" \
      && printf '%s\n' "$on_target" | grep -qxF "$path"; then
      side="both"
    elif printf '%s\n' "$on_branch" | grep -qxF "$path"; then
      side="branch"
    else
      side="target"
    fi
    jq -nc --arg kind "$kind" --arg path "$path" --arg side "$side" \
      '{kind:$kind,path:$path,side:$side}'
  done <<< "$matched"
}

signals_json="$(
  {
    emit_signals dependency  "$DEPENDENCY_RE"  either-side
    emit_signals test-config "$TEST_CONFIG_RE" either-side
    emit_signals migration   "$MIGRATION_RE"   both-sides
  } | jq -s '.'
)"

signal_count="$(printf '%s' "$signals_json" | jq 'length')"

if [ "$signal_count" -eq 0 ]; then
  jq -nc --arg target "$target" --argjson moved "$moved" \
    '{ok:true,moved:$moved,signals:[],
      note:($target + " moved " + ($moved|tostring) + " commits — no risk signal")}'
  exit 0
fi

jq -nc --arg target "$target" --argjson moved "$moved" --argjson signals "$signals_json" \
  '{ok:false,moved:$moved,signals:$signals,
    note:(($signals|length|tostring) + " risk signals against " + $target)}'
