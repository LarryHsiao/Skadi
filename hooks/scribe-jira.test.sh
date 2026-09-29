#!/usr/bin/env bash
# Tests for scribe.sh --target=jira. Run by hand: hooks/scribe-jira.test.sh
# No test reaches Jira: a `curl` stub first on PATH records every call, so a
# dry run that touched the network fails loudly. Dummy env-fallback credentials
# satisfy secret.sh without touching Vaultwarden.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/scribe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export JIRA_BASE_URL="https://example.atlassian.net"
# Point secret.sh at a vault the stub refuses, so credentials always come from
# the env vars here — even on a machine where bw serve is unlocked.
export BW_SERVE_URL="http://vault.invalid"
export JIRA_EMAIL="test@example.com"
export JIRA_API_TOKEN="dummy"

STUB_DIR="$WORK/bin"
export CURL_LOG="$WORK/curl.log"
export STUB_BODIES="$WORK/bodies"
mkdir -p "$STUB_DIR" "$STUB_BODIES"
# The stub plays Jira: it logs "<METHOD> <url>", keeps each request body as
# $STUB_BODIES/<METHOD>.json, and answers from canned responses. The duplicate
# search answer comes from $STUB_SEARCH; $STUB_MYSELF_STATUS fails /myself.
cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=""; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    --data-binary|-d) data="$2"; shift ;;
    -w|-H|-u|-F) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in http://vault.invalid/*) exit 7 ;; esac
echo "$method $url" >> "$CURL_LOG"
case "$data" in @-) cat > "$STUB_BODIES/$method.json" ;; @*) cp "${data#@}" "$STUB_BODIES/$method.json" ;; esac
status=200; resp=""
myself='{"accountId":"acc-123"}'
[ -n "${STUB_MYSELF_BODY:-}" ] && myself="$STUB_MYSELF_BODY"
case "$method $url" in
  "GET "*/myself)             status="${STUB_MYSELF_STATUS:-200}"; resp="$myself" ;;
  "GET "*/search/jql*)        resp="${STUB_SEARCH:-{\"issues\":[]\}}" ;;
  "POST "*/rest/api/3/issue)  status=201; resp='{"key":"PSG-42"}' ;;
  "GET "*fields=attachment*)  resp='{"fields":{"attachment":[]}}' ;;
  "POST "*/attachments)       status="${STUB_ATTACH_STATUS:-200}"; resp='[{"id":"900"}]' ;;
  "PUT "*)                    status="${STUB_PUT_STATUS:-204}" ;;
esac
[ -n "$out" ] && printf '%s' "$resp" > "$out"
printf '%s' "$status"
EOF
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"

TITLE='Epic 1 · Test Section — Reminder list'
FIXTURE="$WORK/plan.md"
PRISTINE="$WORK/pristine.md"
cat > "$PRISTINE" <<'EOF'
# Reminder overview
_Source: Figma frame `38000:47648`_

## Epic 1 · Test Section — Reminder list

**Scope**
- Show reminders in a list

**Sub-tasks**
- [ ] **Toolbar**

---

## Open Questions
- Should the list paginate?
EOF
cp "$PRISTINE" "$FIXTURE"

# Fresh fixture, empty request log, and no leftover stub knobs for the next case.
reset() {
  cp "$PRISTINE" "$FIXTURE"
  rm -f "$CURL_LOG" "$STUB_BODIES"/*
  unset STUB_SEARCH STUB_MYSELF_STATUS STUB_MYSELF_BODY STUB_ATTACH_STATUS STUB_PUT_STATUS
}

# The fixture as a re-run finds it: scribe already owns PSG-5.
mark_owned() {
  sed -i.bak "s|^## $TITLE\$|## $TITLE <!-- jira-issue: PSG-5 -->|" "$FIXTURE"
}

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
count() { printf '%s' "$1" | grep -c -- "$2"; }
has() { if printf '%s' "$1" | grep -q -- "$2"; then echo 1; else echo 0; fi; }

# 1. Dry run: prints the Jira create call and an ADF payload, touches no network.
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira 2>&1); code=$?
check "dry run exits 0" "0" "$code"
check "dry run names the Jira create endpoint" "1" "$(count "$out" 'POST  ${JIRA_BASE_URL}/rest/api/3/issue')"
check "payload carries the project key" "1" "$(count "$out" '"key": "PSG"')"
check "payload carries an ADF doc" "1" "$(count "$out" '"type": "doc"')"
check "body points at the attachment instead of an image" "1" "$(has "$out" 'Figma screenshot attached to this issue')"
check "no attachment:// placeholder in a jira body" "0" "$(count "$out" 'attachment://')"
check "dry run made no curl call" "0" "$(cat "$CURL_LOG" 2>/dev/null | wc -l | tr -d ' ')"

# 2. Sub-tasks are not supported on Jira yet: refuse plainly, exit 2.
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --with-subtasks 2>&1); code=$?
check "with-subtasks on jira exits 2" "2" "$code"
check "with-subtasks on jira says why" "1" "$(count "$out" 'not supported yet')"

# 3. An unknown target names jira among the valid ones.
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=linear 2>&1)
check "invalid target lists jira" "1" "$(count "$out" 'youtrack, disk, outline, or jira')"

# 4. Commit, no marker: creates an assigned Task, writes the marker back.
reset
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit 2>&1); code=$?
check "create exits 0" "0" "$code"
check "create posts the issue" "1" "$(count "$(cat "$CURL_LOG")" 'POST https://.*/rest/api/3/issue$')"
check "create assigns the issue to me" "acc-123" "$(jq -r '.fields.assignee.accountId' "$STUB_BODIES/POST.json")"
check "create files it as a Task in PSG" "Task PSG" "$(jq -r '"\(.fields.issuetype.name) \(.fields.project.key)"' "$STUB_BODIES/POST.json")"
check "create reports the issue url" "1" "$(count "$out" 'issue: https://.*/browse/PSG-42')"
check "create writes the marker back" "1" "$(count "$(cat "$FIXTURE")" "## $TITLE <!-- jira-issue: PSG-42 -->")"
check "create without a screenshot attaches nothing" "0" "$(count "$(cat "$CURL_LOG")" '/attachments')"

# 5. Commit with a screenshot: the file is attached to the new issue.
reset
printf 'png' > "$WORK/shot.png"
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --screenshot-path="$WORK/shot.png" 2>&1); code=$?
check "create with screenshot exits 0" "0" "$code"
check "screenshot is attached to the new issue" "1" "$(count "$(cat "$CURL_LOG")" 'POST https://.*/issue/PSG-42/attachments')"

# 6. A same-title issue already exists: stop with exit 75, create nothing.
reset
export STUB_SEARCH="{\"issues\":[{\"key\":\"PSG-7\",\"fields\":{\"summary\":\"$TITLE\"}}]}"
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit 2>&1); code=$?
check "duplicate exits 75" "75" "$code"
check "duplicate names the existing issue" "1" "$(count "$out" 'existing: https://.*/browse/PSG-7')"
check "duplicate creates nothing" "0" "$(count "$(cat "$CURL_LOG")" '^POST ')"

# 7. --force skips the duplicate search and creates anyway.
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --force 2>&1); code=$?
check "force exits 0" "0" "$code"
check "force posts the issue" "1" "$(count "$(cat "$CURL_LOG")" 'POST https://.*/rest/api/3/issue$')"

# 8. /myself fails: stop before creating, so no unassigned issue is left behind.
reset
export STUB_MYSELF_STATUS=401
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit 2>&1); code=$?
check "myself failure exits 1" "1" "$code"
check "myself failure creates nothing" "0" "$(count "$(cat "$CURL_LOG")" '^POST ')"

# 8b. /myself answers 2xx without an accountId: still stop before creating.
reset
export STUB_MYSELF_BODY='{}'
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit 2>&1); code=$?
check "empty accountId exits 1" "1" "$code"
check "empty accountId creates nothing" "0" "$(count "$(cat "$CURL_LOG")" '^POST ')"

# 8c. The screenshot upload fails after the create: the marker is already on the
#     heading, so a re-run updates this issue instead of hitting the duplicate check.
reset
printf 'png' > "$WORK/shot.png"
export STUB_ATTACH_STATUS=500
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --screenshot-path="$WORK/shot.png" 2>&1); code=$?
check "attach failure exits 1" "1" "$code"
check "attach failure names the created issue" "1" "$(count "$out" 'without its screenshot: https://.*/browse/PSG-42')"
check "attach failure keeps the marker" "1" "$(count "$(cat "$FIXTURE")" "<!-- jira-issue: PSG-42 -->")"

# 8d. Marker present: update that issue in place — no search, lookup, or create.
reset; mark_owned
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit 2>&1); code=$?
log="$(cat "$CURL_LOG")"
check "update exits 0" "0" "$code"
check "update puts to the marked issue" "1" "$(count "$log" 'PUT https://.*/rest/api/3/issue/PSG-5$')"
check "update creates nothing" "0" "$(count "$log" '^POST ')"
check "update skips search and lookup" "0" "$(count "$log" 'search/jql\|/myself')"
check "update sends only summary and description" "description summary" "$(jq -r '.fields | keys | join(" ")' "$STUB_BODIES/PUT.json")"
check "update reports the issue" "1" "$(count "$out" 'COMMITTED — jira issue updated')"
check "update leaves one marker on the heading" "1" "$(grep -o 'jira-issue:' "$FIXTURE" | wc -l | tr -d ' ')"

# 8e. Marker present and a screenshot: re-attached to the same issue.
reset; mark_owned
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --screenshot-path="$WORK/shot.png" 2>&1); code=$?
check "update with screenshot exits 0" "0" "$code"
check "update re-attaches to the marked issue" "1" "$(count "$(cat "$CURL_LOG")" 'POST https://.*/issue/PSG-5/attachments')"

# 8f. The update is refused: exit 1 and name the call.
reset; mark_owned
export STUB_PUT_STATUS=403
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --screenshot-path="$WORK/shot.png" 2>&1); code=$?
check "update failure exits 1" "1" "$code"
check "update failure names the call" "1" "$(count "$out" 'jira issue update failed (http=403)')"
check "update failure attaches nothing" "0" "$(count "$(cat "$CURL_LOG")" '/attachments')"

# 8g. Marker present, dry run: shows the PUT, not the POST.
reset; mark_owned
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira 2>&1)
check "dry run with marker shows the update" "1" "$(count "$out" 'PUT   ${JIRA_BASE_URL}/rest/api/3/issue/PSG-5')"
check "dry run with marker shows no create" "0" "$(count "$out" 'WOULD POST')"

# 9. The file's own `jira-base:` link base still renders the related-ticket link,
#    and no longer shadows the JIRA_BASE_URL credential.
reset
printf '<!-- jira-base: https://files.example.test -->\n' >> "$FIXTURE"
sed -i.bak "s|^## $TITLE\$|## $TITLE <!-- jira: PSG-1 -->|" "$FIXTURE"
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=youtrack 2>&1)
check "jira link marker renders against the file's base" "1" "$(has "$out" '\[PSG-1\](https://files.example.test/browse/PSG-1)')"
out=$("$HOOK" "$FIXTURE" test-section --project=PSG --target=jira --commit --force 2>&1); code=$?
check "file base does not shadow the credential" "0" "$code"
check "the issue lives on the credential's host" "1" "$(count "$out" '^issue: https://example.atlassian.net/browse/PSG-42$')"

exit $fail
