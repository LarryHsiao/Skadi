#!/bin/bash
# Offline tests for amon-din-github.sh — recent GitHub Actions runs for one workflow.
# AMON_DIN_GITHUB_FIXTURE feeds a recorded `gh run list --json` body so the real
# `gh` never runs. Run: bash amon-din-github.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/amon-din-github.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · every gh status/conclusion pair lands in the normalised vocabulary ──
cat >"$ROOT/runs.json" <<'EOF'
[
  {"number":7,"status":"in_progress","conclusion":"","headBranch":"main","updatedAt":"2026-11-07T10:00:00Z","url":"https://github.com/o/r/actions/runs/7"},
  {"number":6,"status":"queued","conclusion":"","headBranch":"main","updatedAt":"2026-11-07T09:00:00Z","url":"https://github.com/o/r/actions/runs/6"},
  {"number":5,"status":"completed","conclusion":"success","headBranch":"main","updatedAt":"2026-11-07T08:00:00Z","url":"https://github.com/o/r/actions/runs/5"},
  {"number":4,"status":"completed","conclusion":"failure","headBranch":"feat/x","updatedAt":"2026-11-07T07:00:00Z","url":"https://github.com/o/r/actions/runs/4"},
  {"number":3,"status":"completed","conclusion":"timed_out","headBranch":"main","updatedAt":"2026-11-07T06:00:00Z","url":"https://github.com/o/r/actions/runs/3"},
  {"number":2,"status":"completed","conclusion":"cancelled","headBranch":"main","updatedAt":"2026-11-07T05:00:00Z","url":"https://github.com/o/r/actions/runs/2"},
  {"number":1,"status":"completed","conclusion":"action_required","headBranch":"main","updatedAt":"2026-11-07T04:00:00Z","url":"https://github.com/o/r/actions/runs/1"}
]
EOF
expected="7|running|main|2026-11-07T10:00:00Z|https://github.com/o/r/actions/runs/7
6|queued|main|2026-11-07T09:00:00Z|https://github.com/o/r/actions/runs/6
5|success|main|2026-11-07T08:00:00Z|https://github.com/o/r/actions/runs/5
4|failed|feat/x|2026-11-07T07:00:00Z|https://github.com/o/r/actions/runs/4
3|failed|main|2026-11-07T06:00:00Z|https://github.com/o/r/actions/runs/3
2|cancelled|main|2026-11-07T05:00:00Z|https://github.com/o/r/actions/runs/2
1|unknown|main|2026-11-07T04:00:00Z|https://github.com/o/r/actions/runs/1"
actual="$(AMON_DIN_GITHUB_FIXTURE="$ROOT/runs.json" bash "$HOOK" o/r ci.yml 7 2>&1)"
check "status and conclusion map to the shared vocabulary" "$expected" "$actual"

# ── 2 · an empty run list prints nothing and succeeds ──
echo '[]' >"$ROOT/empty.json"
actual="$(AMON_DIN_GITHUB_FIXTURE="$ROOT/empty.json" bash "$HOOK" o/r ci.yml 2>&1)"
rc=$?
check "empty run list prints nothing" "" "$actual"
check "empty run list exits 0" "0" "$rc"

# ── 3 · a missing repo or workflow is a usage error ──
bash "$HOOK" >/dev/null 2>&1
check "no arguments exits 1" "1" "$?"
bash "$HOOK" o/r >/dev/null 2>&1
check "repo without workflow exits 1" "1" "$?"

# ── 4 · a body that is not a JSON array is a failure, not a silent empty ──
echo 'not json' >"$ROOT/bad.json"
AMON_DIN_GITHUB_FIXTURE="$ROOT/bad.json" bash "$HOOK" o/r ci.yml >/dev/null 2>&1
check "non-JSON body exits 1" "1" "$?"

# ── 5 · the real call: stderr noise must not corrupt the JSON, and the branch rides along ──
# AMON_DIN_GITHUB_GH swaps in a fake `gh` that prints a notice to stderr, the
# recorded body to stdout, and logs the arguments it was given.
cat >"$ROOT/gh" <<EOF
#!/bin/bash
echo "A new release of gh is available" >&2
echo "\$@" >"$ROOT/gh.args"
cat "$ROOT/runs.json"
EOF
chmod +x "$ROOT/gh"
actual="$(AMON_DIN_GITHUB_GH="$ROOT/gh" bash "$HOOK" o/r ci.yml 1 dev 2>/dev/null | head -1)"
check "a stderr notice from gh does not break the parse" \
  "7|running|main|2026-11-07T10:00:00Z|https://github.com/o/r/actions/runs/7" "$actual"
expected_args="run list --repo o/r --workflow ci.yml --limit 1 --json number,status,conclusion,headBranch,updatedAt,url --branch dev"
check "the repo, workflow, count and branch reach gh" "$expected_args" "$(cat "$ROOT/gh.args")"

# ── 6 · an account names whose token reads the repo, whichever gh account is active ──
# A fake `gh` that knows one login ("work"), logs every call, and records the
# GH_TOKEN a `run list` call was made with.
cat >"$ROOT/gh-accounts" <<EOF
#!/bin/bash
echo "\$@" >>"$ROOT/acct.calls"
if [[ "\$1 \$2" == "auth token" ]]; then
  [[ "\$4" == "work" ]] && { echo "tok-work"; exit 0; }
  echo "no token found for \$4" >&2; exit 1
fi
echo "\${GH_TOKEN-unset}" >"$ROOT/acct.token"
cat "$ROOT/runs.json"
EOF
chmod +x "$ROOT/gh-accounts"

rm -f "$ROOT/acct.calls" "$ROOT/acct.token"
actual="$(env -u GH_TOKEN AMON_DIN_GITHUB_ACCOUNT=work AMON_DIN_GITHUB_GH="$ROOT/gh-accounts" bash "$HOOK" o/r ci.yml 1 2>/dev/null | head -1)"
check "an account's runs are read" \
  "7|running|main|2026-11-07T10:00:00Z|https://github.com/o/r/actions/runs/7" "$actual"
check "gh run list is called with the account's token" "tok-work" "$(cat "$ROOT/acct.token")"

rm -f "$ROOT/acct.calls" "$ROOT/acct.token"
env -u GH_TOKEN AMON_DIN_GITHUB_ACCOUNT=ghost AMON_DIN_GITHUB_GH="$ROOT/gh-accounts" \
  bash "$HOOK" o/r ci.yml >/dev/null 2>"$ROOT/acct.err"
check "an account gh does not hold exits 1" "1" "$?"
check "the failure names the account" "1" "$(grep -c 'ghost' "$ROOT/acct.err")"
check "no run list is attempted for an unknown account" "0" "$(grep -c '^run list' "$ROOT/acct.calls")"

rm -f "$ROOT/acct.calls" "$ROOT/acct.token"
env -u GH_TOKEN AMON_DIN_GITHUB_GH="$ROOT/gh-accounts" bash "$HOOK" o/r ci.yml 1 >/dev/null 2>&1
check "without an account the active gh account is used (no token set)" "unset" "$(cat "$ROOT/acct.token")"
check "without an account no token lookup is made" "0" "$(grep -c '^auth token' "$ROOT/acct.calls")"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
