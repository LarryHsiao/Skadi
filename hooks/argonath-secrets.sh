#!/usr/bin/env bash
# argonath-secrets.sh — scan for secrets in either the unpushed diff or the project tree.
#
# Default (no flag): reads `git diff @{upstream}..HEAD` (the range about to be
# pushed). If no upstream is set, falls back to `HEAD` so a fresh branch is
# still scanned. Inspects only added lines (those starting with `+`, ignoring
# `+++` headers).
#
# `--project`: scans every tracked file in the repo for the same patterns.
# Untracked / `.gitignore`d paths stay out. Binary files are skipped.
#
# Output: single-line JSON
#   { "ok": bool, "count": int, "hits": [string], "note": string }
#
# Patterns covered (ERE):
#   - AWS access keys                                        AKIA[0-9A-Z]{16}
#   - GitHub PATs / OAuth / user / server / refresh tokens   gh[pousr]_[A-Za-z0-9]{36,}
#   - Slack tokens                                           xox[abprs]-…
#   - Stripe live/test secrets                               sk|pk_live|test_…
#   - PEM private keys                                       -----BEGIN … PRIVATE KEY-----
#   - K/V assignments with a non-trivial value               (API_KEY|TOKEN|…)=value
#
# Exit 0 always — caller reads `ok`. Non-fatal errors leave `ok=true,count=0`
# with an explanatory note.
set -u

mode="diff"
if [ "${1:-}" = "--project" ]; then
  mode="project"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  jq -nc '{ok:true,count:0,hits:[],note:"not a git repo"}'
  exit 0
fi
# A root that cannot be entered leaves nothing scanned. Reporting ok:true here
# would be the worst answer this hook can give: the caller reads it as "no
# secrets in the diff" when what happened is that no diff was ever read. An
# unverified tree and a verified clean one are different findings, and only one
# of them is safe to push on.
if ! cd "$REPO_ROOT"; then
  jq -nc '{ok:false,count:0,hits:[],note:"repo root could not be entered — nothing scanned"}'
  exit 1
fi

re='AKIA[0-9A-Z]{16}'
re+='|gh[pousr]_[A-Za-z0-9]{36,}'
re+='|xox[abprs]-[A-Za-z0-9-]+'
re+='|(sk|pk)_(live|test)_[A-Za-z0-9]{20,}'
re+='|-----BEGIN [A-Z ]*PRIVATE KEY-----'
re+='|(API_KEY|API_TOKEN|SECRET|PASSWORD|TOKEN|PRIVATE_KEY)[[:space:]]*=[[:space:]]*["'"'"'`]?[A-Za-z0-9_./+=-]{12,}'

if [ "$mode" = "project" ]; then
  scope_note="project tree (tracked files)"
  hits="$(git ls-files -z 2>/dev/null \
    | xargs -0 grep -IEHni "$re" 2>/dev/null \
    || true)"
else
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    range="${upstream}..HEAD"
  else
    range="HEAD"
  fi
  scope_note="diff range: $range"
  hits="$(git diff -U0 "$range" 2>/dev/null \
    | grep -E '^\+[^+]' \
    | grep -E -i "$re" \
    || true)"
fi

if [ -z "$hits" ]; then
  jq -nc --arg note "$scope_note" '{ok:true,count:0,hits:[],note:$note}'
  exit 0
fi

hits_json="$(printf '%s\n' "$hits" | jq -R -s 'split("\n") | map(select(length>0))')"
count="$(printf '%s' "$hits_json" | jq 'length')"

jq -nc --argjson hits "$hits_json" --arg note "$scope_note" --argjson count "$count" \
  '{ok:false,count:$count,hits:$hits,note:$note}'
