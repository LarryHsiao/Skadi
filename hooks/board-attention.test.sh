#!/bin/bash
# Offline tests for board-attention.sh — the "what awaits me" channel writer.
# BOARD_ATTENTION_FIXTURE_DIR feeds pre-recorded <surface>.out / <surface>.rc
# pairs so the real fetch never runs. Run: bash board-attention.test.sh
set -uo pipefail

WRITER="$(cd "$(dirname "$0")" && pwd)/board-attention.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · populated counts and detail ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/mrs.out" <<'EOF'
review|group/proj|10|Fix bug|https://gitlab.example.com/group/proj/-/merge_requests/10|false|ok
review|group/proj|11|Add feature|https://gitlab.example.com/group/proj/-/merge_requests/11|false|processing
mine|group/proj|12|My MR|https://gitlab.example.com/group/proj/-/merge_requests/12|true|ok
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="3/2 to review · 1 mine/stirred"
actual="$(jq -r '"\(.count)/\(.detail)/\(.verdict)"' "$d/attention-mrs.json")"
check "populated counts and detail" "$expected" "$actual"

# ── 2 · empty output -> count 0 / quiet ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/mrs.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="0/—/quiet"
actual="$(jq -r '"\(.count)/\(.detail)/\(.verdict)"' "$d/attention-mrs.json")"
check "empty output writes count 0 / quiet" "$expected" "$actual"

# ── 3 · rc=1 -> count null / unknown / exit 0 / file still written ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/mrs.out"
echo "1" >"$fx/mrs.rc"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
rc=$?
expected="0/null/unknown/yes"
wrote="$([[ -f "$d/attention-mrs.json" ]] && echo yes || echo no)"
actual="$rc/$(jq -r '.count' "$d/attention-mrs.json")/$(jq -r '.verdict' "$d/attention-mrs.json")/$wrote"
check "a failed fetch (rc=1) still exits 0, writes count null / unknown" "$expected" "$actual"

# ── 4 · CI-failed suffix ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/mrs.out" <<'EOF'
review|group/proj|20|Broken|https://gitlab.example.com/group/proj/-/merge_requests/20|false|failed
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="1 to review · 1 CI failed"
actual="$(jq -r '.detail' "$d/attention-mrs.json")"
check "a failed pipeline appends the CI-failed suffix" "$expected" "$actual"

# ── 5 · channel registered in channels.json ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/mrs.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="yes"
actual="$(jq -e '.channels | index("attention-mrs.json") != null' "$d/channels.json" >/dev/null 2>&1 && echo yes || echo no)"
check "the channel joins the manifest" "$expected" "$actual"

# ── 6 · id and updated present ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/mrs.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="attention-mrs/present"
id="$(jq -r '.id' "$d/attention-mrs.json")"
upd="$(jq -r 'if .updated then "present" else "missing" end' "$d/attention-mrs.json")"
actual="$id/$upd"
check "id and updated are stamped" "$expected" "$actual"

# ── 7 · door host derived from web_url ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/mrs.out" <<'EOF'
review|group/proj|10|Fix bug|https://gitlab.example.com/group/proj/-/merge_requests/10|false|ok
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="https://gitlab.example.com/dashboard/merge_requests"
actual="$(jq -r '.url' "$d/attention-mrs.json")"
check "the door's host comes from the payload, not a hardcoded gitlab.com" "$expected" "$actual"

# ── 8 · a web_url bearing a double quote yields url: null ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/mrs.out" <<'EOF'
review|group/proj|40|Bad host|https://gitlab"x.example.com/group/proj/-/merge_requests/40|false|ok
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="null"
actual="$(jq -r '.url' "$d/attention-mrs.json")"
check "a quote-bearing url is rejected, not interpolated" "$expected" "$actual"

# ── 9 · missing surface arg exits non-zero, writes nothing ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$WRITER" >/dev/null 2>&1
rc=$?
shopt -s nullglob
wrote_any=""
for _f in "$d"/attention-*.json; do wrote_any="yes"; done
shopt -u nullglob
expected="nonzero/no"
actual="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)/${wrote_any:-no}"
check "missing surface arg fails loud, writes nothing" "$expected" "$actual"

# ── 10 · prs shares the forge tally unchanged ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/prs.out" <<'EOF'
review|owner/repo|5|Fix bug|https://github.com/owner/repo/pull/5|false|ok
mine|owner/repo|6|My PR|https://github.com/owner/repo/pull/6|false|ok
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" prs >/dev/null 2>&1
expected="2/1 to review · 1 mine/stirred/https://github.com/pulls"
actual="$(jq -r '"\(.count)/\(.detail)/\(.verdict)/\(.url)"' "$d/attention-prs.json")"
check "prs reuses the shared forge tally, door from payload host" "$expected" "$actual"

# ── 11 · prs's own auth branch: rc=1 -> null / unknown, never a false 0 ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/prs.out"
echo "1" >"$fx/prs.rc"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" prs >/dev/null 2>&1
rc=$?
expected="0/null/unknown"
actual="$rc/$(jq -r '.count' "$d/attention-prs.json")/$(jq -r '.verdict' "$d/attention-prs.json")"
check "prs auth failure (rc=1) never reads as a false 0 / quiet" "$expected" "$actual"

# ── 12 · jira: API_ERROR sentinel -> null / unknown, exit 0 ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
echo 'API_ERROR|field assignee is not valid' >"$fx/jira.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" jira >/dev/null 2>&1
rc=$?
expected="0/null/unknown"
actual="$rc/$(jq -r '.count' "$d/attention-jira.json")/$(jq -r '.verdict' "$d/attention-jira.json")"
check "jira API_ERROR sentinel writes count null / unknown, exit 0" "$expected" "$actual"

# ── 13 · jira: EMPTY sentinel -> count 0 / quiet ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
echo 'EMPTY' >"$fx/jira.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" jira >/dev/null 2>&1
expected="0/quiet"
actual="$(jq -r '"\(.count)/\(.verdict)"' "$d/attention-jira.json")"
check "jira EMPTY sentinel writes count 0 / quiet" "$expected" "$actual"

# ── 14 · jira: populated -> grouped detail, stirred ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
cat >"$fx/jira.out" <<'EOF'
ISSUE|In Progress|M|PSG-1|Fix the thing
ISSUE|In Progress|M|PSG-2|Fix another thing
ISSUE|Done|M|PSG-3|Shipped thing
EOF
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" jira >/dev/null 2>&1
expected="3/2 In Progress · 1 Done/stirred"
actual="$(jq -r '"\(.count)/\(.detail)/\(.verdict)"' "$d/attention-jira.json")"
check "jira groups the detail by status, in order of first appearance" "$expected" "$actual"

# ── 15 · mail: a valid --from-json payload writes the channel ──
d=$(tmpdir)
payload="$d/mail.json"
echo '{"count": 3, "detail": "2 from humans · 1 flagged", "url": "https://outlook.office.com/mail/"}' >"$payload"
BOARD_DIR="$d" bash "$WRITER" mail --from-json "$payload" >/dev/null 2>&1
rc=$?
expected="0/3/2 from humans · 1 flagged/stirred/https://outlook.office.com/mail/"
actual="$rc/$(jq -r '"\(.count)/\(.detail)/\(.verdict)/\(.url)"' "$d/attention-mail.json")"
check "a valid mail payload writes the channel" "$expected" "$actual"

# ── 16 · mail: a bad .count exits non-zero ──
d=$(tmpdir)
payload="$d/mail.json"
echo '{"count": "three", "detail": "bad"}' >"$payload"
BOARD_DIR="$d" bash "$WRITER" mail --from-json "$payload" >/dev/null 2>&1
rc=$?
expected="nonzero"
actual="$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "a non-numeric .count exits non-zero" "$expected" "$actual"

# ── 17 · mail --clear unlinks and re-manifests ──
d=$(tmpdir)
payload="$d/mail.json"
echo '{"count": 1, "detail": "1 flagged"}' >"$payload"
BOARD_DIR="$d" bash "$WRITER" mail --from-json "$payload" >/dev/null 2>&1
BOARD_DIR="$d" bash "$WRITER" mail --clear >/dev/null 2>&1
expected="no/no"
gone="$([[ -f "$d/attention-mail.json" ]] && echo yes || echo no)"
in_manifest="$(jq -e '.channels | index("attention-mail.json") != null' "$d/channels.json" >/dev/null 2>&1 && echo yes || echo no)"
actual="$gone/$in_manifest"
check "--clear unlinks the channel and re-manifests" "$expected" "$actual"

# ── 18 · mail --clear on a never-written channel is a no-op ──
d=$(tmpdir)
BOARD_DIR="$d" bash "$WRITER" mail --clear >/dev/null 2>&1
rc=$?
expected="zero"
actual="$([[ $rc -eq 0 ]] && echo zero || echo nonzero)"
check "--clear on a never-written channel is a no-op, exits 0" "$expected" "$actual"

# ── 19 · mrs: a category sitting exactly on the page cap reads as capped ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/mrs.out"
for i in $(seq 1 50); do
  echo "review|group/proj|$i|Item $i|https://gitlab.example.com/group/proj/-/merge_requests/$i|false|ok" >>"$fx/mrs.out"
done
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" mrs >/dev/null 2>&1
expected="50 to review (capped)"
actual="$(jq -r '.detail' "$d/attention-mrs.json")"
check "a category sitting on the page cap is marked (capped)" "$expected" "$actual"

# ── 20 · jira: exactly 50 ISSUE lines reads as capped ──
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/jira.out"
for i in $(seq 1 50); do
  echo "ISSUE|In Progress|M|PSG-$i|Item $i" >>"$fx/jira.out"
done
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" bash "$WRITER" jira >/dev/null 2>&1
expected="50/50 In Progress (capped)"
actual="$(jq -r '"\(.count)/\(.detail)"' "$d/attention-jira.json")"
check "jira at exactly maxResults reads as capped, not an exact count" "$expected" "$actual"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
