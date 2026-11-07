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

# A vault whose /status hangs but whose item list answers. A preflight on /status
# turns that into a silent skip of the whole lookup (see the note in secret.sh).
# The list call carries its own timeout, so the lookup must not depend on /status.
FAKE_DIR="$(mktemp -d)"
cat >"$FAKE_DIR/vault.py" <<'PY'
import http.server, json, socketserver, time

ITEMS = {"success": True, "data": {"data": [{
    "name": "svc", "notes": None,
    "login": {"password": "pw", "username": "u", "uris": [{"uri": "https://vault.example.test"}]}}]}}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            time.sleep(30)
            return
        body = json.dumps(ITEMS).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$FAKE_DIR/vault.py" >"$FAKE_DIR/port" &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null; rm -rf "$FAKE_DIR"' EXIT
for _ in $(seq 50); do [ -s "$FAKE_DIR/port" ] && break; sleep 0.1; done

expected_uri="https://vault.example.test"
actual_uri="$(BW_SERVE_URL="http://127.0.0.1:$(cat "$FAKE_DIR/port")" "$HERE/secret.sh" svc uri - 2>/dev/null)"
check "a vault whose /status hangs still answers from its item list" "$expected_uri" "$actual_uri"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
