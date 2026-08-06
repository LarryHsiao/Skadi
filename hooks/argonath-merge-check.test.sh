#!/bin/bash
# Offline tests for the merge-tree conflict probe. Run from anywhere: bash argonath-merge-check.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-merge-check.sh"
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

first_path() { # json
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["conflicted_paths"][0] if d["conflicted_paths"] else "")' 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

commit() { # message, run inside the target repo
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "$1"
}

# ── no target given ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no target given exits 0" "0" "$st"
check "no target given reports ok" "True" "$(field "$out" ok)"
check "no target given names no conflicts" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["conflicted_paths"]))')"

# ── a target that does not resolve locally ──
PLAIN="$WORK/plain"
git init -q -b work "$PLAIN"
( cd "$PLAIN" && commit --allow-empty init )
out=$(cd "$PLAIN" && "$HOOK" definitely-not-a-real-branch 2>/dev/null); st=$?
check "an unresolved target exits 0" "0" "$st"
check "an unresolved target reports ok" "True" "$(field "$out" ok)"

# ── a genuine textual conflict: both branches edit the same line ──
CONFLICT="$WORK/conflict"
git init -q -b work "$CONFLICT"
(
  cd "$CONFLICT"
  printf 'line one\n' > shared.txt
  git add shared.txt
  commit base
  git branch target
  printf 'line one\nfeature change\n' > shared.txt
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -am feature
  git checkout -q target
  printf 'line one\ntarget change\n' > shared.txt
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -am target-change
  git checkout -q work
)
out=$(cd "$CONFLICT" && "$HOOK" target 2>/dev/null); st=$?
check "a genuine conflict still exits 0 (caller reads ok, not exit code)" "0" "$st"
check "a genuine conflict reports ok:false" "False" "$(field "$out" ok)"
check "a genuine conflict names the conflicting file" "shared.txt" "$(first_path "$out")"

# ── a clean merge: branches touch different files ──
CLEAN="$WORK/clean"
git init -q -b work "$CLEAN"
(
  cd "$CLEAN"
  printf 'base\n' > a.txt
  git add a.txt
  commit base
  git branch target
  printf 'feature\n' > b.txt
  git add b.txt
  commit feature
  git checkout -q target
  printf 'target\n' > c.txt
  git add c.txt
  commit target-change
  git checkout -q work
)
out=$(cd "$CLEAN" && "$HOOK" target 2>/dev/null); st=$?
check "a clean merge exits 0" "0" "$st"
check "a clean merge reports ok:true" "True" "$(field "$out" ok)"
check "a clean merge names no conflicts" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["conflicted_paths"]))')"

expected_keys="conflicted_paths,note,ok"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

# ── a `merge-tree` that errors without ever printing a CONFLICT line — an old
# git lacking --write-tree, or any other unexpected failure — must degrade to
# ok:true, not read as a false hold ──
STUB="$WORK/stub"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/git" <<'SCRIPT'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--verify" ]; then
  exit 0
fi
if [ "${1:-}" = "merge-tree" ]; then
  echo "fatal: unknown option --write-tree" >&2
  exit 128
fi
exit 0
SCRIPT
chmod +x "$STUB/bin/git"
out=$(PATH="$STUB/bin:$PATH" "$HOOK" some-target 2>/dev/null); st=$?
check "a non-CONFLICT merge-tree error exits 0" "0" "$st"
check "a non-CONFLICT merge-tree error degrades to ok:true" "True" "$(field "$out" ok)"
check "a non-CONFLICT merge-tree error names no conflicts" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["conflicted_paths"]))')"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
