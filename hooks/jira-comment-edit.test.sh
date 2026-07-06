#!/usr/bin/env bash
# Test for the [[PLAN-PREVIEW]] -> mediaSingle sentinel in jira-comment-edit.sh.
# Run by hand: hooks/jira-comment-edit.test.sh
# Mirrors hooks/council-jira-comment.test.sh — same sentinel, edit path.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/jira-comment-edit.sh"

# See hooks/council-jira-comment.test.sh for why JIRA_URL/JIRA_USERNAME (not
# JIRA_BASE_URL/JIRA_EMAIL) are secret.sh's actual auto-mapped env fallback names.
export JIRA_URL="https://example.atlassian.net"
export JIRA_USERNAME="test@example.com"
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

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "mediaSingle type present" "1" "$(printf '%s' "$out" | grep -c '"type": "mediaSingle"')"
check "attachment id embedded" "1" "$(printf '%s' "$out" | grep -c '"id": "12345"')"

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | "$HOOK" MET-1 999)
check "no env var -> sentinel stays literal text" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"

out=$(printf 'Plain paragraph, nothing special.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "no sentinel -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"

exit $fail
