#!/usr/bin/env bash
# Test for the [[PLAN-PREVIEW]] -> mediaSingle sentinel in council-jira-comment.sh.
# Run by hand: hooks/council-jira-comment.test.sh
# Uses COUNCIL_DRY_RUN=1 so no network call is made; dummy env-fallback
# credentials satisfy the non-empty checks without touching Vaultwarden.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/council-jira-comment.sh"

# council-jira-comment.sh overrides all three secret.sh env-fallback names
# explicitly (uri->JIRA_BASE_URL, username->JIRA_EMAIL, password->JIRA_API_TOKEN)
# rather than relying on secret.sh's own auto-mapping — these exports must
# match those overrides. They only matter if no live Vaultwarden "jira" item
# is unlocked; if one is, the vault answers first and these exports are
# unused (harmless either way since COUNCIL_DRY_RUN=1 gates every network
# call regardless of which credentials resolved).
export JIRA_BASE_URL="https://example.atlassian.net"
export JIRA_EMAIL="test@example.com"
export JIRA_API_TOKEN="dummy"
export COUNCIL_DRY_RUN=1

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    fail=1
  fi
}

# 1. Sentinel present + JIRA_ATTACHMENT_ID set -> mediaSingle node.
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1)
check "mediaSingle type present" "1" "$(printf '%s' "$out" | grep -c '"type": "mediaSingle"')"
check "attachment id embedded" "1" "$(printf '%s' "$out" | grep -c '"id": "12345"')"
check "collection is jira" "1" "$(printf '%s' "$out" | grep -c '"collection": "jira"')"
check "sentinel text not emitted literally" "0" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"

# 2. Sentinel present but no JIRA_ATTACHMENT_ID -> emitted as plain text (unchanged behavior).
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | "$HOOK" MET-1)
check "no env var -> sentinel stays literal text" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"
check "no env var -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"

# 3. No sentinel at all -> unaffected (today's behavior).
out=$(printf 'Plain paragraph, nothing special.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1)
check "no sentinel -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"
check "no sentinel -> plain text intact" "1" "$(printf '%s' "$out" | grep -c 'Plain paragraph')"

# 4. Sentinel plus extra text (not an exact match) -> plain text, not mediaSingle.
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]] extra text\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1)
check "sentinel-plus-extra -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"
check "sentinel-plus-extra -> literal text preserved" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW.. extra text')"

exit $fail
