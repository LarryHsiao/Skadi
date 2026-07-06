#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../../../hooks/vor-normalize.sh"
FIX="$DIR/../fixtures"

actual="$("$SCRIPT" --me "U-ME" < "$FIX/delta-sample.json" | jq -S .)"
expected="$(jq -S . < "$FIX/expected-normalized.json")"

if [ "$actual" = "$expected" ]; then
  echo "PASS test-normalize"
else
  echo "FAIL test-normalize"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
  exit 1
fi
