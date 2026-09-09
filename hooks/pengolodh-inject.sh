#!/usr/bin/env bash
# pengolodh-inject.sh — on SessionStart, inject this repo's Pengolodh
# mechanism cache (see pengolodh.sh) as additional context, then kick off a
# detached sync so the network never sits between the user and their
# session. Silent no-op when the repo has no cache yet, or when git/
# .autosync aren't configured (pengolodh.sh sync is itself a no-op then).
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pengolodh.sh"

contents="$(bash "$script" inject "$root" 2>/dev/null)" || exit 0
[[ -n "$contents" ]] || exit 0

framed="Mechanism cache for this repo (pengolodh — run \`bash ~/.claude/hooks/pengolodh.sh status <repo-root>\` for details):

${contents}"

jq -n --arg ctx "$framed" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

# Detached: never let the network sit between the user and their session.
( bash "$script" sync >/dev/null 2>&1 & ) 2>/dev/null
disown 2>/dev/null || true
