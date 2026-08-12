#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo" "$TMP/outside"

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

cat > "$TMP/context-hook.sh" <<'SH'
#!/usr/bin/env bash
payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path')"
jq -n --arg value "$(basename "$path")" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$value}}'
SH
chmod +x "$TMP/context-hook.sh"

payload="$(jq -n --arg cwd "$TMP/repo" '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: one.txt\n+x\n*** Add File: two.txt\n+y\n*** End Patch"}}')"
output="$(printf '%s' "$payload" | "$HERE/codex-hook-adapter.sh" "$TMP/context-hook.sh")"
check "multi-file context is returned as one JSON object" 1 "$(printf '%s' "$output" | jq -s 'length')"
check "multi-file contexts are combined" $'one.txt\ntwo.txt' "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"

patch_payload="$(jq -n --arg cwd "$TMP/repo" '{cwd:$cwd,tool_name:"apply_patch",tool_input:{patch:"*** Begin Patch\n*** Add File: patch-field.txt\n+x\n*** End Patch"}}')"
patch_output="$(printf '%s' "$patch_payload" | "$HERE/codex-hook-adapter.sh" "$TMP/context-hook.sh")"
check "native patch field is adapted" patch-field.txt "$(printf '%s' "$patch_output" | jq -r '.hookSpecificOutput.additionalContext')"

inside="$(jq -n --arg cwd "$TMP/repo" '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: inside.txt\n+x\n*** End Patch"}}')"
inside_output="$(printf '%s' "$inside" | HOME=/private/tmp CODEX_HOME=/private/tmp/.codex "$HERE/codex-hook-adapter.sh" "$HERE/dir-guard.sh")"
check "inside patch is allowed" allow "$(printf '%s' "$inside_output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"

outside="$(jq -n --arg cwd "$TMP/repo" '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: /Users/skadi-outside/no.txt\n+x\n*** End Patch"}}')"
outside_output="$(printf '%s' "$outside" | HOME=/private/tmp CODEX_HOME=/private/tmp/.codex "$HERE/codex-hook-adapter.sh" "$HERE/dir-guard.sh")"
check "escaping patch is denied" deny "$(printf '%s' "$outside_output" | jq -r '.hookSpecificOutput.permissionDecision // empty')"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
