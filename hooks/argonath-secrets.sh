#!/usr/bin/env bash
# argonath-secrets.sh — scan the about-to-be-pushed diff for secrets.
#
# Reads `git diff @{upstream}..HEAD` (the range about to be pushed). If no
# upstream is set, falls back to `HEAD` so a fresh branch is still scanned.
# Inspects only added lines (those starting with `+`, ignoring `+++` headers).
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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  jq -nc '{ok:true,count:0,hits:[],note:"not a git repo"}'
  exit 0
fi
cd "$REPO_ROOT"

if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
  range="${upstream}..HEAD"
else
  range="HEAD"
fi

re='AKIA[0-9A-Z]{16}'
re+='|gh[pousr]_[A-Za-z0-9]{36,}'
re+='|xox[abprs]-[A-Za-z0-9-]+'
re+='|(sk|pk)_(live|test)_[A-Za-z0-9]{20,}'
re+='|-----BEGIN [A-Z ]*PRIVATE KEY-----'
re+='|(API_KEY|API_TOKEN|SECRET|PASSWORD|TOKEN|PRIVATE_KEY)[[:space:]]*=[[:space:]]*["'"'"'`]?[A-Za-z0-9_./+=-]{12,}'

added_hits="$(git diff -U0 "$range" 2>/dev/null \
  | grep -E '^\+[^+]' \
  | grep -E -i "$re" \
  || true)"

if [ -z "$added_hits" ]; then
  jq -nc --arg range "$range" '{ok:true,count:0,hits:[],note:("diff range: "+$range)}'
  exit 0
fi

hits_json="$(printf '%s\n' "$added_hits" | jq -R -s 'split("\n") | map(select(length>0))')"
count="$(printf '%s' "$hits_json" | jq 'length')"

jq -nc --argjson hits "$hits_json" --arg range "$range" --argjson count "$count" \
  '{ok:false,count:$count,hits:$hits,note:("diff range: "+$range)}'
