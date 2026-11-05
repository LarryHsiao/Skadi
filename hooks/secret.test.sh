#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# An unreachable vault, so only the env fallback and the miss path are exercised.
export BW_SERVE_URL="http://127.0.0.1:1"

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

# Hyphenated service, nothing in vault or env: a clean miss, not a bash abort.
expected_miss="secret.sh: 'orthanc-winsparkle-dsa.password' not in Vaultwarden (bw serve at $BW_SERVE_URL) or env \$ORTHANC_WINSPARKLE_DSA_TOKEN"
miss_err="$("$HERE/secret.sh" orthanc-winsparkle-dsa 2>&1 >/dev/null)"
miss_code=$?
check "hyphenated miss exits 1" 1 "$miss_code"
check "hyphenated miss names the mapped env var" "$expected_miss" "$miss_err"

# Hyphenated service with the mapped env var set: the fallback reads it.
expected_value="dsa-secret"
actual_value="$(ORTHANC_WINSPARKLE_DSA_TOKEN="$expected_value" "$HERE/secret.sh" orthanc-winsparkle-dsa 2>/dev/null)"
check "hyphenated service reads ORTHANC_WINSPARKLE_DSA_TOKEN" "$expected_value" "$actual_value"

# Plain service keeps its existing mapping.
expected_plain="jira-secret"
actual_plain="$(JIRA_TOKEN="$expected_plain" "$HERE/secret.sh" jira 2>/dev/null)"
check "plain service still reads JIRA_TOKEN" "$expected_plain" "$actual_plain"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
