#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VOR_STATE_DIR="$(mktemp -d)"; export VOR_STATE_DIR
. "$DIR/../../../hooks/vor-cursor.sh"
FIX="$DIR/../fixtures"
SRC="https://graph.microsoft.com/v1.0/chats/AAA/messages/delta"

# 1. No cursor yet → url is the base source.
u1="$(vor_cursor_url "$SRC")"
[ "$u1" = "$SRC" ] || { echo "FAIL: expected base url on first run, got '$u1'"; exit 1; }

# 2. Save the deltaLink from a response, then url must be that link.
vor_cursor_save "$SRC" "$FIX/delta-with-deltalink.json"
expected_link="$(jq -r '."@odata.deltaLink"' < "$FIX/delta-with-deltalink.json")"
u2="$(vor_cursor_url "$SRC")"
[ "$u2" = "$expected_link" ] || { echo "FAIL: expected saved deltaLink, got '$u2'"; exit 1; }

echo "PASS test-cursor"
