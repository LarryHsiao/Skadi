#!/bin/bash
# Offline tests for argonath-run.sh's secret placeholders. Run from anywhere:
#   bash argonath-run.test.sh
# No test reaches Vaultwarden: secret.sh is pointed at a vault that refuses, so
# every value comes from its env fallback.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-run.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

field() { # json key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export SKADI_PROFILE="personal"
export BW_SERVE_URL="http://vault.invalid"
export METIS_TEST_USERNAME="s3cret-user"
SECRET_VALUE="s3cret-user"

REPO="$WORK/repo"
git init -q -b work "$REPO"
ENV_FILE=$("$HERE/skadi-state.sh" path personal "$REPO" test_env.md)

# The stand-in for a test runner: it records the argument it was handed and
# echoes it, as a failing test printing its input might.
STUB="$WORK/runner.sh"
printf '#!/bin/bash\nprintf "%%s" "$1" > "%s/seen"\necho "got $1"\n' "$WORK" > "$STUB"
chmod +x "$STUB"

run() { (cd "$REPO" && "$HOOK" Tests "$STUB" "$@"); }

# ── no placeholder: the command runs verbatim, as before ──
out=$(run plain)
expected_ok="True"
check "a command with no placeholder runs" "$expected_ok" "$(field "$out" ok)"

# ── the missing file is named, and the command never runs ──
rm -f "$WORK/seen"
out=$(run "--acct={{TEST_ACCOUNT}}")
expected_ok="False"
check "a placeholder with no test_env.md fails" "$expected_ok" "$(field "$out" ok)"
expected_summary="test_env.md does not declare TEST_ACCOUNT — add it at $ENV_FILE"
check "the missing test_env.md is named with its path" "$expected_summary" "$(field "$out" summary)"
expected_ran="no"
check "the command does not run without its secret" "$expected_ran" "$([ -f "$WORK/seen" ] && echo yes || echo no)"

# ── a file that declares other names still names the missing one ──
printf 'OTHER=secret:Metis_Test:password\n' > "$ENV_FILE"
out=$(run "--acct={{TEST_ACCOUNT}}")
expected_summary="test_env.md does not declare TEST_ACCOUNT — add it at $ENV_FILE"
check "an undeclared name is named" "$expected_summary" "$(field "$out" summary)"

# ── a declared secret is swapped in, and kept out of every record ──
printf '# comment\nTEST_ACCOUNT=secret:Metis_Test:username\n' > "$ENV_FILE"
out=$(run "--acct={{TEST_ACCOUNT}}")
expected_ok="True"
check "a declared secret runs the command" "$expected_ok" "$(field "$out" ok)"
expected_seen="--acct=$SECRET_VALUE"
check "the command receives the real value" "$expected_seen" "$(cat "$WORK/seen" 2>/dev/null)"
# Only the tail is compared: on Windows, jq's output rewrites the stub's
# /tmp path into C:/…, which says nothing about the placeholder.
expected_command_tail="--acct={{TEST_ACCOUNT}}"
recorded=$(field "$out" command)
check "the recorded command keeps the placeholder" "$expected_command_tail" "${recorded##* }"
expected_leaks="0"
check "the log holds no secret value" "$expected_leaks" "$(grep -c "$SECRET_VALUE" "$(field "$out" log)")"

# ── a declared secret the vault cannot give fails loudly ──
printf 'TEST_ACCOUNT=secret:Nowhere_Item:username\n' > "$ENV_FILE"
out=$(run "--acct={{TEST_ACCOUNT}}")
expected_summary="secret unresolved for TEST_ACCOUNT (Nowhere_Item username)"
check "an unresolvable secret is named" "$expected_summary" "$(field "$out" summary)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
