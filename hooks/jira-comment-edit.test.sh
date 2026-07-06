#!/usr/bin/env bash
# Test for the [[PLAN-PREVIEW]] -> attachment-pointer sentinel in jira-comment-edit.sh.
# Run by hand: hooks/jira-comment-edit.test.sh
# Mirrors hooks/council-jira-comment.test.sh — same sentinel, edit path.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/jira-comment-edit.sh"

# See hooks/council-jira-comment.test.sh for why these names match
# jira-comment-edit.sh's explicit secret.sh overrides (uri->JIRA_BASE_URL,
# username->JIRA_EMAIL, password->JIRA_API_TOKEN).
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

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "attachment pointer text present" "1" "$(printf '%s' "$out" | grep -c 'Diagram attached to this issue')"
check "no mediaSingle node" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | "$HOOK" MET-1 999)
check "no env var -> sentinel stays literal text" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"

out=$(printf 'Plain paragraph, nothing special.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "no sentinel -> no pointer text" "0" "$(printf '%s' "$out" | grep -c 'Diagram attached to this issue')"

# Sentinel plus extra text (not an exact match) -> plain text, not the pointer.
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]] extra text\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "sentinel-plus-extra -> no pointer text" "0" "$(printf '%s' "$out" | grep -c 'Diagram attached to this issue')"
check "sentinel-plus-extra -> literal text preserved" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW.. extra text')"

exit $fail
