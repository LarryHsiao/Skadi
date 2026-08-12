#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home"
PROJECT="$TEST_HOME/projects/example"
mkdir -p "$PROJECT"

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

default_dir="$(HOME="$TEST_HOME" "$HERE/skadi-state.sh" project-dir default "$PROJECT")"
paired_dir="$(HOME="$TEST_HOME" "$HERE/skadi-state.sh" project-dir .codex "$PROJECT")"
personal_dir="$(HOME="$TEST_HOME" "$HERE/skadi-state.sh" project-dir personal "$PROJECT")"
check "paired default roots share state" "$default_dir" "$paired_dir"
check "personal profile remains isolated" different "$([ "$default_dir" != "$personal_dir" ] && echo different || echo same)"
check "path resolves below profile project" "$default_dir/jira_config.md" "$(HOME="$TEST_HOME" "$HERE/skadi-state.sh" path default "$PROJECT" jira_config.md)"

canonical_project="$(cd "$PROJECT" && pwd -P)"
legacy_key="${canonical_project//\//-}"
legacy="$TEST_HOME/.claude/projects/$legacy_key/memory"
mkdir -p "$legacy"
printf 'legacy value\n' > "$legacy/jira_config.md"
HOME="$TEST_HOME" "$HERE/skadi-state.sh" migrate default "$PROJECT" "$TEST_HOME/.claude" >/dev/null
check "legacy value migrates when neutral value is absent" "legacy value" "$(cat "$default_dir/jira_config.md")"

printf 'different value\n' > "$legacy/jira_config.md"
HOME="$TEST_HOME" "$HERE/skadi-state.sh" migrate default "$PROJECT" "$TEST_HOME/.claude" >/dev/null 2>&1
check "migration refuses a conflict" 2 "$?"
check "conflict does not overwrite neutral state" "legacy value" "$(cat "$default_dir/jira_config.md")"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
