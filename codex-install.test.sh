#!/usr/bin/env bash
# Offline integration tests for the native Codex installer.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home"
CODEX_ROOT="$TEST_HOME/.codex"
mkdir -p "$CODEX_ROOT"

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

printf 'model = "keep-me"\n' > "$CODEX_ROOT/config.toml"
cp "$CODEX_ROOT/config.toml" "$TMP/config.before"
printf '# User guidance\n\nKeep this paragraph.\n' > "$CODEX_ROOT/AGENTS.md"
cat > "$CODEX_ROOT/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "/usr/bin/true"}]}
    ]
  }
}
JSON

HOME="$TEST_HOME" bash "$HERE/install.sh" --codex "$CODEX_ROOT" >/dev/null

check "config.toml is untouched" yes "$(cmp -s "$TMP/config.before" "$CODEX_ROOT/config.toml" && echo yes || echo no)"
check "user AGENTS text is preserved" yes "$(rg -q 'Keep this paragraph' "$CODEX_ROOT/AGENTS.md" && echo yes || echo no)"
check "one managed AGENTS block is installed" 1 "$(rg -c '<!-- skadi:start -->' "$CODEX_ROOT/AGENTS.md")"
check "user hook is preserved" true "$(jq -r '.hooks.SessionEnd[0].hooks[0].command == "/usr/bin/true"' "$CODEX_ROOT/hooks.json")"
check "Skadi hooks are installed" true "$(jq -r '[.. | strings | select(contains("codex-hook-adapter.sh"))] | length > 0' "$CODEX_ROOT/hooks.json")"
check "Skadi rules are installed" yes "$([ -f "$CODEX_ROOT/rules/skadi.rules" ] && echo yes || echo no)"
check "hook adapter stays executable" yes "$([ -x "$CODEX_ROOT/hooks/codex-hook-adapter.sh" ] && echo yes || echo no)"
check "rendered skill uses Codex invocation" yes "$(rg -q '\$commit' "$CODEX_ROOT/skills/commit/SKILL.md" && echo yes || echo no)"
check "rendered skill has neutral state instruction" yes "$(rg -q 'skadi-state.sh path default' "$CODEX_ROOT/skills/commit/SKILL.md" && echo yes || echo no)"
check "rendered skill has no Claude hook path" no "$(rg -q '[~]/.claude/hooks' "$CODEX_ROOT/skills/commit/SKILL.md" && echo yes || echo no)"
check "all rendered skill resources avoid Claude hook paths" no "$(rg -q '[~]/.claude/hooks' "$CODEX_ROOT/skills" && echo yes || echo no)"
check "all rendered skill resources avoid Claude question tool names" no "$(rg -q 'AskUserQuestion|ScheduleWakeup' "$CODEX_ROOT/skills" && echo yes || echo no)"

bad_frontmatter=0
while IFS= read -r skill; do
  keys="$(sed -n '2,/^---$/p' "$skill" | sed '$d' | sed -n 's/^\([A-Za-z0-9_-]*\):.*/\1/p' | sort | tr '\n' ' ')"
  [ "$keys" = "description name " ] || bad_frontmatter=$((bad_frontmatter + 1))
done < <(find "$CODEX_ROOT/skills" -name SKILL.md -type f)
check "all rendered skills have strict frontmatter" 0 "$bad_frontmatter"
unsafe_frontmatter=0
while IFS= read -r skill; do
  [ "$(rg -c '^(name|description): "' "$skill")" = 2 ] || unsafe_frontmatter=$((unsafe_frontmatter + 1))
done < <(find "$CODEX_ROOT/skills" -name SKILL.md -type f)
check "all rendered skill names/descriptions are safely quoted" 0 "$unsafe_frontmatter"
schema_violations="$(python3 - "$CODEX_ROOT/skills" <<'PY'
import json, re, sys
from pathlib import Path
bad = 0
for path in Path(sys.argv[1]).glob("*/SKILL.md"):
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        name = json.loads(lines[1].split(":", 1)[1].strip())
        description = json.loads(lines[2].split(":", 1)[1].strip())
    except (IndexError, ValueError):
        bad += 1
        continue
    if name != path.parent.name or not re.fullmatch(r"[a-z0-9-]{1,64}", name):
        bad += 1
    if not description or len(description) > 1024 or "<" in description or ">" in description:
        bad += 1
print(bad)
PY
)"
check "all rendered skills meet Codex name/description constraints" 0 "$schema_violations"

# Reinstall: managed blocks/groups must be replaced, not duplicated.
HOME="$TEST_HOME" bash "$HERE/install.sh" --codex "$CODEX_ROOT" >/dev/null
check "AGENTS merge is idempotent" 1 "$(rg -c '<!-- skadi:start -->' "$CODEX_ROOT/AGENTS.md")"
adapter_count="$(jq '[.. | strings | select(contains("codex-hook-adapter.sh"))] | length' "$CODEX_ROOT/hooks.json")"
HOME="$TEST_HOME" bash "$HERE/install.sh" --codex "$CODEX_ROOT" >/dev/null
check "hook merge is idempotent" "$adapter_count" "$(jq '[.. | strings | select(contains("codex-hook-adapter.sh"))] | length' "$CODEX_ROOT/hooks.json")"

# Manifest pruning may remove only a path Skadi previously recorded.
mkdir -p "$CODEX_ROOT/hooks"
printf 'stale\n' > "$CODEX_ROOT/hooks/skadi-stale-test.sh"
printf 'hooks/skadi-stale-test.sh\n' >> "$CODEX_ROOT/.skadi-installed-files"
HOME="$TEST_HOME" bash "$HERE/install.sh" --codex "$CODEX_ROOT" >/dev/null
check "manifest-owned stale file is pruned" no "$([ -e "$CODEX_ROOT/hooks/skadi-stale-test.sh" ] && echo yes || echo no)"

# A custom pair shares the Claude-derived registry profile on both sides.
CUSTOM_CLAUDE="$TEST_HOME/custom-claude"
CUSTOM_CODEX="$TEST_HOME/different-codex-name"
HOME="$TEST_HOME" bash "$HERE/install.sh" --pair "$CUSTOM_CLAUDE" "$CUSTOM_CODEX" >/dev/null
check "custom pair records one shared profile" custom-claude "$(cut -f1 "$TEST_HOME/.skadi/install/roots.tsv")"
check "Claude settings receive the shared profile" custom-claude "$(jq -r '.env.SKADI_PROFILE' "$CUSTOM_CLAUDE/settings.json")"
check "Codex skills receive the shared profile" yes "$(rg -q 'skadi-state.sh path custom-claude' "$CUSTOM_CODEX/skills/commit/SKILL.md" && echo yes || echo no)"

# A machine with no registry is registered with one pair, not three — and the
# run closes by naming how to add a second, since nothing else would tell the
# user the option exists. A fresh HOME, not TEST_HOME: the pair test above has
# already written a registry there.
FRESH_HOME="$TMP/fresh"
mkdir -p "$FRESH_HOME"
HOME="$FRESH_HOME" bash "$HERE/install.sh" --all > "$TMP/fresh-all.txt" 2>&1
expected_rows=1
check "a fresh registry holds one pair" "$expected_rows" "$(awk 'NF' "$FRESH_HOME/.skadi/install/roots.tsv" | wc -l | tr -d ' ')"
expected_profile=default
check "the one pair is default" "$expected_profile" "$(cut -f1 "$FRESH_HOME/.skadi/install/roots.tsv")"
expected_home=no
check "no personal home is created" "$expected_home" "$([ -e "$FRESH_HOME/.claude-personal" ] && echo yes || echo no)"
check "no work home is created" "$expected_home" "$([ -e "$FRESH_HOME/.claude-work" ] && echo yes || echo no)"
expected_standing="One profile is registered: default — $FRESH_HOME/.claude | $FRESH_HOME/.codex"
expected_shown=yes
check "the close names the standing pair" "$expected_shown" "$(grep -qxF "$expected_standing" "$TMP/fresh-all.txt" && echo yes || echo no)"
check "the close names --pair" "$expected_shown" "$(grep -q -- '--pair ~/.claude-work' "$TMP/fresh-all.txt" && echo yes || echo no)"
check "the close names how to launch one" "$expected_shown" "$(grep -q 'CLAUDE_CONFIG_DIR="\$HOME/.claude-work" claude' "$TMP/fresh-all.txt" && echo yes || echo no)"
check "the close names the Codex home" "$expected_shown" "$(grep -q 'CODEX_HOME="\$HOME/.codex-work" codex' "$TMP/fresh-all.txt" && echo yes || echo no)"
check "the close offers an alias" "$expected_shown" "$(grep -q "alias claude-work='CLAUDE_CONFIG_DIR" "$TMP/fresh-all.txt" && echo yes || echo no)"

# A single CUSTOM pair must be named as itself: announcing ~/.claude to someone
# whose only home is elsewhere would tell them something untrue about their own
# install.
CUSTOM_HOME="$TMP/custom"
mkdir -p "$CUSTOM_HOME"
HOME="$CUSTOM_HOME" bash "$HERE/install.sh" --pair \
  "$CUSTOM_HOME/.claude-solo" "$CUSTOM_HOME/.codex-solo" >/dev/null 2>&1
HOME="$CUSTOM_HOME" bash "$HERE/install.sh" --all > "$TMP/custom-all.txt" 2>&1
expected_custom="One profile is registered: solo — $CUSTOM_HOME/.claude-solo | $CUSTOM_HOME/.codex-solo"
check "a lone custom pair is named as itself" "$expected_shown" "$(grep -qxF "$expected_custom" "$TMP/custom-all.txt" && echo yes || echo no)"

# Once a second pair stands the hint has served its purpose and falls silent.
printf 'work\t%s\t%s\n' "$FRESH_HOME/.claude-work" "$FRESH_HOME/.codex-work" \
  >> "$FRESH_HOME/.skadi/install/roots.tsv"
HOME="$FRESH_HOME" bash "$HERE/install.sh" --all > "$TMP/fresh-two.txt" 2>&1
expected_silent=no
check "a second pair silences the hint" "$expected_silent" "$(grep -q 'CLAUDE_CONFIG_DIR' "$TMP/fresh-two.txt" && echo yes || echo no)"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
