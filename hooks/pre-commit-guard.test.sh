#!/bin/bash
# Offline tests for the pre-commit secrets guard. Run from anywhere: bash pre-commit-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/pre-commit-guard.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Reads .hookSpecificOutput.<key> out of the hook's JSON reply, or "" for
# both a missing key and a genuinely empty reply (the guard prints nothing
# at all when it finds no sensitive files — that silence means "allow").
field() { # json key
  [ -z "$1" ] && return 0
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hookSpecificOutput", {}).get(sys.argv[1], ""))' "$2" 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK"
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test

# Stages one file, runs the hook against a `git commit` command with that
# file as the only staged change, then unstages/removes it so each case
# starts clean. Echoes the hook's raw stdout.
run_case() { # filename content
  local file="$1" content="$2"
  mkdir -p "$WORK/$(dirname "$file")"
  printf '%s' "$content" > "$WORK/$file"
  git -C "$WORK" add "$file"
  local input
  input=$(python3 -c 'import json; print(json.dumps({"tool_input": {"command": "git commit -m test"}}))')
  (cd "$WORK" && printf '%s' "$input" | "$HOOK")
  # `restore --staged` needs a resolvable HEAD, which a from-scratch repo
  # with no commits never has ("fatal: could not resolve 'HEAD'") — `rm
  # --cached` unstages unconditionally, commit or no commit.
  git -C "$WORK" rm --cached -f "$file" >/dev/null 2>&1 || true
  rm -f "$WORK/$file"
}

# ── the false positive this change exists to fix: a *.env-suffixed config
# file is not the dotenv naming convention and carries no secret here ──
out=$(run_case "versions.env" "NA_VERSION_CODE=378")
check "versions.env (not dotenv-named) is not flagged" "" "$out"

out=$(run_case "build.env" "SOME_VAR=1")
check "build.env (not dotenv-named) is not flagged" "" "$out"

out=$(run_case "config/versions.env" "NA_VERSION_CODE=378")
check "nested versions.env (not dotenv-named) is not flagged" "" "$out"

# ── the contract this change must not break: real dotenv files, in a
# subdirectory or not, are still caught ──
out=$(run_case ".env" "SECRET=abc")
check ".env is flagged" "deny" "$(field "$out" permissionDecision)"

out=$(run_case ".env.production" "SECRET=abc")
check ".env.production is flagged" "deny" "$(field "$out" permissionDecision)"

out=$(run_case "config/.env" "SECRET=abc")
check "nested .env is flagged" "deny" "$(field "$out" permissionDecision)"

# ── the other patterns on the same line are untouched by this change ──
out=$(run_case "credentials.json" "{}")
check "credentials.json is flagged" "deny" "$(field "$out" permissionDecision)"

out=$(run_case "id_rsa.pem" "-----BEGIN-----")
check "id_rsa.pem is flagged" "deny" "$(field "$out" permissionDecision)"

# ── a non-commit command must never be evaluated, regardless of what's staged ──
mkdir -p "$WORK"
printf '%s' "SECRET=abc" > "$WORK/.env"
git -C "$WORK" add ".env"
input=$(python3 -c 'import json; print(json.dumps({"tool_input": {"command": "git status"}}))')
out=$(cd "$WORK" && printf '%s' "$input" | "$HOOK")
check "a non-commit command is never evaluated" "" "$out"
git -C "$WORK" rm --cached -f ".env" >/dev/null 2>&1 || true
rm -f "$WORK/.env"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
