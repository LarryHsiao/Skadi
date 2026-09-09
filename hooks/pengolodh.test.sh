#!/bin/bash
# Offline tests for pengolodh.sh + pengolodh.py. Uses the seams PENGOLODH_DIR
# (a temp cache root) and PENGOLODH_INJECT_BUDGET (a tiny inject cap, to
# exercise the low-confidence drop without a huge fixture). Every fixture
# "repo" is a plain temp dir — verify/inject need no real git repo, only
# sync does. Run: bash pengolodh.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PENGOLODH="$HERE/pengolodh.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

contains() {
  if [[ "$2" == *"$3"* ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected output to contain [$3], got [$2]"; fail=$((fail + 1)); fi
}

# ── 1 · path resolves and creates the index's directory ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
check "path prints an index.md under the cache root" "1" "$([[ "$idx" == "$cache"/*/index.md ]] && echo 1 || echo 0)"
check "path creates the directory (not just the name)" "1" "$([[ -d "$(dirname "$idx")" ]] && echo 1 || echo 0)"

# ── 2 · status on an empty cache: no entries, git absent, invitation printed ──
cache=$(tmpdir)
repo=$(tmpdir)
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" status "$repo")
contains "empty cache reports 0 entries" "$out" "entries: 0"
contains "no git yet offers the init invitation" "$out" "not initialized"

# ── 3 · a hand-written entry is counted by status ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf -- '- **thing** — `f.txt:1` — desc <!-- a:needle c:high -->\n' >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" status "$repo")
contains "one written entry is counted" "$out" "entries: 1"

# ── 4 · verify: MOVED — the anchored literal is still in the file, at a new line ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf 'one\ntwo\nthree\nfour\nneedle here\n' >"$repo/f.txt"
printf -- '- **thing** — `f.txt:1` — desc <!-- a:needle c:high -->\n' >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" verify "$repo")
contains "a moved literal is reported MOVED" "$out" "MOVED"
contains "verify's summary line counts the move" "$out" "moved=1 stale=0 missing=0"
repaired=$(cat "$idx")
contains "the index line is rewritten to the new line number" "$repaired" '`f.txt:5`'

# ── 5 · verify: STALE — the file exists, but the literal is gone from it ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf 'one\ntwo\n' >"$repo/f.txt"
printf -- '- **thing** — `f.txt:1` — desc <!-- a:needle c:high -->\n' >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" verify "$repo")
contains "a vanished literal is reported STALE" "$out" "STALE"
contains "verify's summary line counts the staleness" "$out" "moved=0 stale=1 missing=0"
unchanged=$(cat "$idx")
contains "a stale entry's line number is left alone" "$unchanged" '`f.txt:1`'

# ── 6 · verify: MISSING — the anchored file itself is gone ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf -- '- **thing** — `gone.txt:1` — desc <!-- a:needle c:high -->\n' >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" verify "$repo")
contains "a deleted file is reported MISSING" "$out" "MISSING"
contains "verify's summary line counts the deletion" "$out" "moved=0 stale=0 missing=1"

# ── 6b · verify: a rel_path escaping the repo is treated as MISSING, never
#        read ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
secret=$(tmpdir)
printf 'outside-needle\n' >"$secret/secret.txt"
rel="../$(basename "$secret")/secret.txt"
printf -- '- **escape attempt** — `%s:1` — desc <!-- a:outside-needle c:high -->\n' "$rel" >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" verify "$repo")
contains "an escaping rel_path is reported MISSING, not read" "$out" "MISSING"

# ── 7 · inject withholds STALE/MISSING and keeps OK/MOVED ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf 'ok-needle\n' >"$repo/ok.txt"
{
  printf -- '- **kept** — `ok.txt:1` — desc <!-- a:ok-needle c:high -->\n'
  printf -- '- **dropped** — `gone.txt:1` — desc <!-- a:x c:high -->\n'
} >"$idx"
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" inject "$repo")
contains "inject keeps a still-valid entry" "$out" "kept"
if [[ "$out" == *"dropped"* ]]; then
  echo "  FAIL · inject withholds a MISSING entry — it printed [dropped]"; fail=$((fail + 1))
else
  echo "  ok  · inject withholds a MISSING entry"; pass=$((pass + 1))
fi
contains "inject notes how many were withheld" "$out" "withheld"

# ── 8 · inject drops low-confidence entries when over budget ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf 'high-needle\nlow-needle\n' >"$repo/f.txt"
{
  printf -- '- **kept** — `f.txt:1` — desc <!-- a:high-needle c:high -->\n'
  printf -- '- **dropped** — `f.txt:2` — desc <!-- a:low-needle c:low -->\n'
} >"$idx"
out=$(PENGOLODH_DIR="$cache" PENGOLODH_INJECT_BUDGET=1 "$PENGOLODH" inject "$repo")
contains "over budget keeps the high-confidence entry" "$out" "kept"
if [[ "$out" == *$'\n- **dropped**'* ]]; then
  echo "  FAIL · over-budget inject should drop the low-confidence entry"; fail=$((fail + 1))
else
  echo "  ok  · over-budget inject drops the low-confidence entry"; pass=$((pass + 1))
fi
contains "inject notes the length-driven drop" "$out" "dropped for length"

# ── 9 · gc deletes confirmed-dead entries, leaves live and low-confidence-
#       but-valid entries alone ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
printf 'live-needle\n' >"$repo/f.txt"
{
  printf -- '- **kept-ok** — `f.txt:1` — desc <!-- a:live-needle c:high -->\n'
  printf -- '- **kept-low** — `f.txt:1` — desc <!-- a:live-needle c:low -->\n'
  printf -- '- **dropped-missing** — `gone.txt:1` — desc <!-- a:x c:high -->\n'
} >"$idx"
gc_out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" gc "$repo")
contains "gc reports how many it removed" "$gc_out" "removed 1 stale/missing entry"
remaining="$(cat "$idx")"
contains "gc keeps a live high-confidence entry" "$remaining" "kept-ok"
contains "gc keeps a live low-confidence entry (uncertain, not dead)" "$remaining" "kept-low"
if [[ "$remaining" == *"dropped-missing"* ]]; then
  echo "  FAIL · gc should have deleted the MISSING entry from the file"; fail=$((fail + 1))
else
  echo "  ok  · gc deletes the MISSING entry from the file"; pass=$((pass + 1))
fi

# ── 10 · gc on an empty/absent index is a harmless no-op ──
cache=$(tmpdir)
repo=$(tmpdir)
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" gc "$repo")
contains "gc on a never-written index reports zero removed" "$out" "removed 0"

# ── 9b · verify/gc commit a dirty index locally when git is present, with
#        no .autosync needed — commit and sync are separate switches ──
cache=$(tmpdir)
repo=$(tmpdir)
idx=$(PENGOLODH_DIR="$cache" "$PENGOLODH" path "$repo")
git -C "$cache" init -q >/dev/null
printf 'needle\n' >"$repo/f.txt"
printf -- '- **hand-appended** — `f.txt:1` — desc <!-- a:needle c:high -->\n' >"$idx"
# No .autosync anywhere — commit must not depend on it.
PENGOLODH_DIR="$cache" "$PENGOLODH" verify "$repo" >/dev/null
dirty="$(git -C "$cache" status --porcelain -- . 2>/dev/null)"
check "verify commits a hand-appended entry with no .autosync set" "" "$dirty"
log_msg="$(git -C "$cache" log -1 --format=%s 2>/dev/null)"
contains "the commit message names the index that changed" "$log_msg" "index.md"

# gc's own deletion must also land as its own commit.
printf -- '- **dead** — `gone.txt:1` — desc <!-- a:x c:high -->\n' >>"$idx"
git -C "$cache" -c user.email=t@e.com -c user.name=T commit -aqm "add a dead entry" >/dev/null
PENGOLODH_DIR="$cache" "$PENGOLODH" gc "$repo" >/dev/null
dirty_after_gc="$(git -C "$cache" status --porcelain -- . 2>/dev/null)"
check "gc commits its own deletion" "" "$dirty_after_gc"

# ── 11 · sync is a silent no-op when git is absent ──
cache=$(tmpdir)
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" sync 2>&1)
check "sync with no git prints nothing" "" "$out"

# ── 12 · sync is a silent no-op when .autosync is not set ──
cache=$(tmpdir)
git -C "$cache" init -q >/dev/null
out=$(PENGOLODH_DIR="$cache" "$PENGOLODH" sync 2>&1)
check "sync with git but no .autosync prints nothing" "" "$out"

# ── 13 · sync propagates an entry from one clone to another ──
# init.defaultBranch=main on the bare repo so its HEAD symref names a branch
# that will actually exist once cache_a's first push lands — otherwise a
# later clone checks out nothing and every fixture below cascades to fail.
origin=$(tmpdir)
git -c init.defaultBranch=main init -q --bare "$origin" >/dev/null

cache_a=$(tmpdir); rmdir "$cache_a"
git clone -q "$origin" "$cache_a" >/dev/null 2>&1
mkdir -p "$cache_a/repo-key"
echo "entry one" >"$cache_a/repo-key/index.md"
git -C "$cache_a" add -A
git -c user.email=test@example.com -c user.name=Test -C "$cache_a" commit -q -m seed
git -C "$cache_a" push -q -u origin main
touch "$cache_a/.autosync"

cache_b=$(tmpdir); rmdir "$cache_b"
git clone -q "$origin" "$cache_b" >/dev/null 2>&1
git -C "$cache_b" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
touch "$cache_b/.autosync"

PENGOLODH_DIR="$cache_b" "$PENGOLODH" sync >/dev/null 2>&1
received="$(cat "$cache_b/repo-key/index.md" 2>/dev/null || echo MISSING)"
check "a synced clone receives the pushed entry" "entry one" "$received"

synced_status=$(PENGOLODH_DIR="$cache_b" "$PENGOLODH" status "$ROOT")
contains "status reports synced once nothing is ahead or behind" "$synced_status" "git: synced"

# ── 14 · status reports "behind N" once a fetch has seen a remote move ──
# git_posture() reads local refs only (HEAD vs @{u}) and never fetches on its
# own — our own sync verb always fetches and ff-only-merges in one call, so
# a clean "behind, not diverged" state is a narrow window in practice (a
# fetch with no merge). Fetch by hand here to exercise git_posture() itself.
echo "cache_a change" >>"$cache_a/repo-key/index.md"
git -c user.email=test@example.com -c user.name=Test -C "$cache_a" commit -aqm "a's change"
PENGOLODH_DIR="$cache_a" "$PENGOLODH" sync >/dev/null 2>&1 # a's change reaches origin
git -C "$cache_b" fetch -q origin >/dev/null 2>&1          # cache_b sees the move, does not merge

behind_status=$(PENGOLODH_DIR="$cache_b" "$PENGOLODH" status "$ROOT")
contains "status reports behind once a fetch has seen the remote move" "$behind_status" "behind 1"

# ── 15 · sync stops on divergence, keeps the local copy, and status says so ──
echo "cache_b local change" >>"$cache_b/repo-key/index.md"
git -c user.email=test@example.com -c user.name=Test -C "$cache_b" commit -aqm "b's local change"
before="$(cat "$cache_b/repo-key/index.md")"
PENGOLODH_DIR="$cache_b" "$PENGOLODH" sync >/dev/null 2>&1
after="$(cat "$cache_b/repo-key/index.md")"
check "a diverged sync leaves the local copy untouched" "$before" "$after"

status_out=$(PENGOLODH_DIR="$cache_b" "$PENGOLODH" status "$ROOT")
contains "status reports the divergence" "$status_out" "diverged"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
