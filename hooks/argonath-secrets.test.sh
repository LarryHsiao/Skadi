#!/bin/bash
# Offline tests for the secret scanner. Run from anywhere: bash argonath-secrets.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-secrets.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Reads one field out of the hook's single-line JSON reply.
field() { # json key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A `git` earlier on PATH than the real one, naming a root that does not exist.
# See argonath-detect.test.sh for why a stub beats chmod here.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  echo "/nonexistent/argonath-secrets-fixture"
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/git"

# ── the case that matters: a scanner that could not reach the tree it was
# asked about must never answer "clean". An unverified tree and a verified
# empty one are different answers, and only one of them is safe to act on ──
out=$(PATH="$WORK/bin:$PATH" "$HOOK" 2>/dev/null); st=$?
expected_status="1"
check "an unenterable repo root exits non-zero" "$expected_status" "$st"

expected_ok="False"
check "an unenterable repo root never reports ok" "$expected_ok" "$(field "$out" ok)"

expected_count="0"
check "an unenterable repo root claims no findings either way" "$expected_count" "$(field "$out" count)"

expected_note_empty="no"
note=$(field "$out" note)
check "an unenterable repo root says why in its note" "$expected_note_empty" "$([ -n "$note" ] && echo no || echo yes)"

# ── the contract holds on the happy path, so the guard above was not bought by
# breaking the ordinary road ──
out=$(cd "$HERE" && "$HOOK" 2>/dev/null); st=$?
expected_status="0"
check "a real repo exits 0" "$expected_status" "$st"

expected_keys="count,hits,note,ok"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

# ── the range: a merge gate must read everything the branch brings, pushed or
# not. Each case builds a throwaway repo with a bare origin ──
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Split so this file never matches its own pattern.
SECRET="AKIA""ABCDEFGHIJKLMNOP"

# fixture <name> — a repo at $WORK/<name>/work with master pushed to origin.
fixture() {
  local root="$WORK/$1"
  git init -q --bare "$root/origin.git"
  git init -q -b master "$root/work"
  git -C "$root/work" remote add origin "$root/origin.git"
  echo base > "$root/work/a.txt"
  git -C "$root/work" add a.txt && git -C "$root/work" commit -qm base
  git -C "$root/work" push -q -u origin master 2>/dev/null
  echo "$root/work"
}

# commit_file <repo> <file> <content>
commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2" && git -C "$1" commit -qm "add $2"
}

repo=$(fixture pushed)
git -C "$repo" switch -q -c feat/x
commit_file "$repo" key.txt "aws=$SECRET"
git -C "$repo" push -q -u origin HEAD 2>/dev/null
out=$(cd "$repo" && "$HOOK" master 2>/dev/null)
expected_ok="False"
check "a pushed branch's own secret is caught against the target" "$expected_ok" "$(field "$out" ok)"

repo=$(fixture unpushed)
git -C "$repo" switch -q -c feat/y
git -C "$repo" branch -q --unset-upstream 2>/dev/null
commit_file "$repo" key.txt "aws=$SECRET"
out=$(cd "$repo" && "$HOOK" 2>/dev/null)
expected_ok="False"
check "a committed secret with no upstream and no target is caught" "$expected_ok" "$(field "$out" ok)"

repo=$(fixture clean)
git -C "$repo" switch -q -c feat/z
commit_file "$repo" b.txt "nothing here"
git -C "$repo" push -q -u origin HEAD 2>/dev/null
base=$(git -C "$repo" merge-base master HEAD)
out=$(cd "$repo" && "$HOOK" master 2>/dev/null)
expected_ok="True"
check "a clean pushed branch passes against the target" "$expected_ok" "$(field "$out" ok)"
expected_note="diff range: ${base}..HEAD"
check "the note names the merge-base range" "$expected_note" "$(field "$out" note)"

repo=$(fixture onmaster)
commit_file "$repo" key.txt "aws=$SECRET"
out=$(cd "$repo" && "$HOOK" master 2>/dev/null)
expected_ok="False"
check "on the target itself, an unpushed secret is caught via upstream" "$expected_ok" "$(field "$out" ok)"
expected_note="diff range: origin/master..HEAD"
check "on the target itself, the upstream range is used" "$expected_note" "$(field "$out" note)"

out=$(cd "$repo" && "$HOOK" no-such-branch 2>/dev/null); st=$?
expected_status="0"
check "a missing target does not error" "$expected_status" "$st"
expected_note="diff range: origin/master..HEAD"
check "a missing target falls back to the upstream range" "$expected_note" "$(field "$out" note)"

repo=$(fixture unrelated)
git -C "$repo" switch -q --orphan stray
commit_file "$repo" key.txt "aws=$SECRET"
out=$(cd "$repo" && "$HOOK" master 2>/dev/null)
expected_ok="False"
check "a target sharing no history falls back to the whole tree" "$expected_ok" "$(field "$out" ok)"

# ── a diff that could not be read is not a clean diff. A `git` that passes
# everything through but fails `diff` stands in for a corrupt object ──
REAL_GIT="$(command -v git)"
mkdir -p "$WORK/faildiff"
cat > "$WORK/faildiff/git" <<STUB
#!/bin/bash
if [ "\${1:-}" = "diff" ]; then
  echo "fatal: bad object" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$WORK/faildiff/git"
repo=$(fixture broken)
out=$(cd "$repo" && PATH="$WORK/faildiff:$PATH" "$HOOK" master 2>/dev/null); st=$?
expected_status="1"
check "a failing git diff exits non-zero" "$expected_status" "$st"
expected_ok="False"
check "a failing git diff never reports ok" "$expected_ok" "$(field "$out" ok)"
expected_note="git diff failed on origin/master..HEAD — nothing scanned"
check "a failing git diff says nothing was scanned" "$expected_note" "$(field "$out" note)"

# ── a repo with no commits has nothing to leak — and says so, rather than
# passing by way of the same silence ──
git init -q -b master "$WORK/empty"
out=$(cd "$WORK/empty" && "$HOOK" 2>/dev/null); st=$?
expected_status="0"
check "a repo with no commits exits 0" "$expected_status" "$st"
expected_ok="True"
check "a repo with no commits reports ok" "$expected_ok" "$(field "$out" ok)"
expected_note="no commits yet — nothing to scan"
check "a repo with no commits says why" "$expected_note" "$(field "$out" note)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
