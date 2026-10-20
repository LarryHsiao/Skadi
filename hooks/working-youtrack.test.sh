#!/usr/bin/env bash
# Tests for working-youtrack-ticket.sh and working-youtrack-open.sh.
# Run by hand: hooks/working-youtrack.test.sh
# No test reaches YouTrack: a `curl` stub first on PATH logs every argument and
# answers /api/issues from $STUB_BODY with $STUB_STATUS. Dummy env-fallback
# credentials satisfy secret.sh without touching Vaultwarden.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TICKET_HOOK="$HERE/working-youtrack-ticket.sh"
OPEN_HOOK="$HERE/working-youtrack-open.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Point secret.sh at a vault the stub refuses, so credentials always come from
# the env vars here — even on a machine where bw serve is unlocked.
export BW_SERVE_URL="http://vault.invalid"
export YOUTRACK_URL="https://youtrack.example.test"
export YOUTRACK_TOKEN="dummy"

STUB_DIR="$WORK/bin"
export CURL_LOG="$WORK/curl.log"
export STUB_BODY="$WORK/body.json"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  printf '%s\n' "$1" >> "$CURL_LOG"
  case "$1" in
    -o) out="$2"; shift; printf '%s\n' "$1" >> "$CURL_LOG" ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in http://vault.invalid/*) exit 7 ;; esac
[ -n "$out" ] && cp "$STUB_BODY" "$out"
printf '%s' "${STUB_STATUS:-200}"
EOF
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"

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
reset() { : > "$CURL_LOG"; unset STUB_STATUS; }
logged() { if grep -qxF -- "$1" "$CURL_LOG"; then echo 1; else echo 0; fi; }

# 1. Ticket hook maps all five fields from the custom fields.
reset
cat > "$STUB_BODY" <<'EOF'
{"summary":"B4 · 登入 bottom sheet","description":"Show the sheet.","customFields":[
 {"name":"Type","value":{"name":"Task"}},
 {"name":"State","value":{"name":"In Progress"}},
 {"name":"Priority","value":{"name":"Normal"}},
 {"name":"Assignee","value":{"name":"Larry Hsiao"}}]}
EOF
expected='{"summary":"B4 · 登入 bottom sheet","status":"In Progress","type":"Task","priority":"Normal","description":"Show the sheet."}'
out=$("$TICKET_HOOK" MET-42); code=$?
check "ticket: exits 0" "0" "$code"
check "ticket: maps summary/status/type/priority/description" "$expected" "$out"

# 2. Absent fields become empty strings, not null.
reset
echo '{"summary":"Bare","description":null}' > "$STUB_BODY"
expected='{"summary":"Bare","status":"","type":"","priority":"","description":""}'
out=$("$TICKET_HOOK" MET-1)
check "ticket: absent fields are empty" "$expected" "$out"

# 3. Missing id is a usage error.
reset
out=$("$TICKET_HOOK"); code=$?
check "ticket: no id exits non-zero" "1" "$code"
check "ticket: no id names usage" "1" "$(printf '%s' "$out" | grep -c usage)"

# 4. HTTP failure surfaces the status.
reset
echo '{"error":"nope"}' > "$STUB_BODY"
out=$(STUB_STATUS=404 "$TICKET_HOOK" MET-404); code=$?
check "ticket: http failure exits non-zero" "1" "$code"
check "ticket: http failure names the status" "1" "$(printf '%s' "$out" | grep -c 'http=404')"

# 5. Open hook maps id/state/summary, keeping the server's order.
reset
cat > "$STUB_BODY" <<'EOF'
[{"idReadable":"MET-42","summary":"Login sheet","customFields":[{"name":"State","value":{"name":"In Progress"}}]},
 {"idReadable":"MET-7","summary":"Splash","customFields":[{"name":"State","value":{"name":"Open"}}]}]
EOF
expected='[{"key":"MET-42","status":"In Progress","summary":"Login sheet"},{"key":"MET-7","status":"Open","summary":"Splash"}]'
out=$("$OPEN_HOOK" MET 5); code=$?
check "open: exits 0" "0" "$code"
check "open: maps key/status/summary" "$expected" "$out"
check "open: query scopes project, unresolved, newest first" "1" "$(logged 'query=project: MET #Unresolved sort by: updated desc')"
check "open: honours MAX" "1" "$(logged '$top=5')"

# 6. MAX defaults to 20.
reset
"$OPEN_HOOK" MET >/dev/null
check "open: MAX defaults to 20" "1" "$(logged '$top=20')"

# 7. Missing project key is a usage error.
reset
out=$("$OPEN_HOOK"); code=$?
check "open: no project exits non-zero" "1" "$code"
check "open: no project names usage" "1" "$(printf '%s' "$out" | grep -c usage)"

# 8. HTTP failure surfaces the status.
reset
echo '{"error":"boom"}' > "$STUB_BODY"
out=$(STUB_STATUS=500 "$OPEN_HOOK" MET); code=$?
check "open: http failure exits non-zero" "1" "$code"
check "open: http failure names the status" "1" "$(printf '%s' "$out" | grep -c 'http=500')"

# 9. Missing credentials stop both hooks before any YouTrack call.
for hook in "$TICKET_HOOK" "$OPEN_HOOK"; do
  name=$(basename "$hook" .sh)
  reset
  out=$(YOUTRACK_TOKEN="" "$hook" MET-1); code=$?
  check "$name: missing creds exits non-zero" "1" "$code"
  check "$name: missing creds names credentials" "1" "$(printf '%s' "$out" | grep -c 'credentials missing')"
  check "$name: missing creds makes no YouTrack call" "0" "$(grep -c 'youtrack.example.test' "$CURL_LOG")"
done

exit $fail
