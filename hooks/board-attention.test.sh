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

# ── 2b · the same empty result under the system bash ──
# The hooks run as `#!/bin/bash`, which is 3.2 on macOS, where reading an empty
# array under `set -u` is an unbound variable. Test 2 runs under whatever `bash`
# is first on PATH (5.x here) and cannot see it, so this one names /bin/bash.
d=$(tmpdir)
fx="$d/fixture"
mkdir -p "$fx"
: >"$fx/prs.out"
BOARD_DIR="$d" BOARD_ATTENTION_FIXTURE_DIR="$fx" /bin/bash "$WRITER" prs >/dev/null 2>&1
rc=$?
expected="0/0/—/quiet"
actual="$rc/$(jq -r '"\(.count)/\(.detail)/\(.verdict)"' "$d/attention-prs.json" 2>/dev/null)"
check "an empty result exits 0 and writes count 0 / quiet under /bin/bash" "$expected" "$actual"

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

# ── jira: the source is `halbarad-jira.sh window 24`'s JSON (tickets + why) ──
# tk builds one ticket; window_json folds tickets read from stdin into the brief.
tk() { # tk <key> <summary> <url> <changes-json> <mentions-json> [reopened] [reassigned_to_me]
  jq -nc --arg k "$1" --arg s "$2" --arg u "$3" --argjson c "$4" --argjson m "$5" \
    --argjson r "${6:-false}" --argjson t "${7:-false}" \
    '{key:$k,summary:$s,status:"In Progress",url:$u,updated:"2026-11-24T10:00:00Z",assigned:false,
      reopened:$r,reassigned_to_me:$t,changes:$c,mentions:$m}'
}
window_json() { jq -sc '{source:"jira",status:"ok",tickets:.}'; }
BASE="https://jubo.atlassian.net/browse"
CMT='[{"at":"2026-11-24T10:00:00Z","who":"Chia-Yu","kind":"comment"}]'
FIXV='[{"at":"2026-11-24T10:00:00Z","who":"Louis","kind":"Fix Version"}]'
jira_run() { # jira_run <fixture-dir> <board-dir>
  BOARD_DIR="$2" BOARD_ATTENTION_FIXTURE_DIR="$1" bash "$WRITER" jira >/dev/null 2>&1
}

# ── 12 · jira: an error answer, or one that is not JSON -> null / unknown, exit 0 ──
d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
echo '{"source":"jira","status":"error","reason":"timeout"}' >"$fx/jira.out"; echo 4 >"$fx/jira.rc"
jira_run "$fx" "$d"; rc=$?
expected="0/null/unknown/none"
actual="$rc/$(jq -r '.count' "$d/attention-jira.json")/$(jq -r '.verdict' "$d/attention-jira.json")/$(jq -r '.items // "none"' "$d/attention-jira.json")"
check "jira error answer writes count null / unknown with no items, exit 0" "$expected" "$actual"

d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
echo 'not json at all' >"$fx/jira.out"
jira_run "$fx" "$d"
expected="null/unknown"
actual="$(jq -r '"\(.count)/\(.verdict)"' "$d/attention-jira.json")"
check "jira answer that is not JSON reads unknown, never a false 0" "$expected" "$actual"

# ── 13 · jira: no tickets -> count 0 / quiet, empty list ──
d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
echo '{"source":"jira","status":"ok","tickets":[]}' >"$fx/jira.out"
jira_run "$fx" "$d"
expected="0/quiet/0"
actual="$(jq -r '"\(.count)/\(.verdict)/\(.items | length)"' "$d/attention-jira.json")"
check "jira with no tickets writes count 0 / quiet and no items" "$expected" "$actual"

# ── 14 · jira: populated -> ranked list (mention/reopened, reassigned, rest), top five ──
d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
{
  tk PSG-4930 "Cap the range" "$BASE/PSG-4930" "$CMT" '[]'
  tk PSG-4941 "Pin results" "$BASE/PSG-4941" "$FIXV" '[]'
  tk LTC-4100 "Dual device" "$BASE/LTC-4100" '[{"at":"2026-11-24T09:59:13Z","who":"Yahan Chou","kind":"assignee","to_me":true}]' '[]' false true
  tk PSG-4971 "Re-run API" "$BASE/PSG-4971" '[{"at":"2026-11-24T07:01:58Z","who":"ShawnYeh","kind":"comment"}]' '[{"at":"2026-11-24T07:01:58Z","who":"ShawnYeh","kind":"mention","quote":"q"}]'
  tk PSG-9 "Back again" "$BASE/PSG-9" '[{"at":"2026-11-24T08:00:00Z","who":"Vivian","kind":"status","reopened":true}]' '[]' true
  tk PSG-7 "Seventh" "$BASE/PSG-7" "$CMT" '[]'
  tk PSG-8 "Eighth" "$BASE/PSG-8" "$CMT" '[]'
} | window_json >"$fx/jira.out"
jira_run "$fx" "$d"
expected="7/1 mention · 1 reopened · 1 reassigned · 4 moved/stirred"
actual="$(jq -r '"\(.count)/\(.detail)/\(.verdict)"' "$d/attention-jira.json")"
check "jira counts tickets and names each kind in the detail" "$expected" "$actual"
expected_keys='["PSG-4971","PSG-9","LTC-4100","PSG-4930","PSG-4941"]'
check "jira lists mention and reopened first, then reassigned, then the rest, five at most" "$expected_keys" \
  "$(jq -c '[.items[].key]' "$d/attention-jira.json")"
expected_why='["mention · ShawnYeh","reopened · Vivian","assigned to you · Yahan Chou","comment · Chia-Yu","Fix Version · Louis"]'
check "jira gives each listed ticket its reason and who" "$expected_why" "$(jq -c '[.items[].why]' "$d/attention-jira.json")"
expected_tone='["alert","alert","assigned","moved","moved"]'
check "jira tones each reason for the page" "$expected_tone" "$(jq -c '[.items[].tone]' "$d/attention-jira.json")"

# ── 14b · jira: a title is kept verbatim for the page to escape; a non-https url is dropped ──
d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
tk PSG-10 "<b>x</b>" "javascript:alert(1)" "$CMT" '[]' | window_json >"$fx/jira.out"
jira_run "$fx" "$d"
expected="<b>x</b>/null"
actual="$(jq -r '"\(.items[0].summary)/\(.items[0].url)"' "$d/attention-jira.json")"
check "jira keeps the title as text and drops a url that is not https" "$expected" "$actual"

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

# ── 20 · jira: many tickets -> the true count, five listed ──
d=$(tmpdir); fx="$d/fixture"; mkdir -p "$fx"
for i in $(seq 1 60); do tk "PSG-$i" "Item $i" "$BASE/PSG-$i" "$CMT" '[]'; done | window_json >"$fx/jira.out"
jira_run "$fx" "$d"
expected="60/60 moved/5"
actual="$(jq -r '"\(.count)/\(.detail)/\(.items | length)"' "$d/attention-jira.json")"
check "jira reports the true count and lists only five" "$expected" "$actual"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
