#!/bin/bash
# Offline tests for the semantic-drift probe. Run from anywhere: bash argonath-drift.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-drift.sh"
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

signal_count() { # json
  printf '%s' "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["signals"]))' 2>/dev/null
}

signal_kinds() { # json
  printf '%s' "$1" \
    | python3 -c 'import json,sys; print(",".join(sorted({s["kind"] for s in json.load(sys.stdin)["signals"]})))' 2>/dev/null
}

side_of() { # json kind
  printf '%s' "$1" \
    | python3 -c 'import json,sys; print(next((s["side"] for s in json.load(sys.stdin)["signals"] if s["kind"]==sys.argv[1]), ""))' "$2" 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

commit() { # message, run inside the target repo
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "$1"
}

# Builds a repo whose `work` branch and `target` branch each carry one commit
# past a shared base. $1 names the repo; $2 is the file the branch adds, $3 the
# file the target adds. Leaves `work` checked out.
diverged_repo() { # dir branch-file target-file
  local dir="$1" branch_file="$2" target_file="$3"
  git init -q -b work "$dir"
  (
    cd "$dir" || exit 1
    printf 'base\n' > base.txt
    git add base.txt
    commit base
    git branch target
    mkdir -p "$(dirname "$branch_file")"
    printf 'branch side\n' > "$branch_file"
    git add "$branch_file"
    commit branch-change
    git checkout -q target
    mkdir -p "$(dirname "$target_file")"
    printf 'target side\n' > "$target_file"
    git add "$target_file"
    commit target-change
    git checkout -q work
  )
}

# ── no target given ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no target given exits 0" "0" "$st"
check "no target given reports ok" "True" "$(field "$out" ok)"
check "no target given names no signals" "0" "$(signal_count "$out")"

# ── a target that does not resolve locally ──
PLAIN="$WORK/plain"
git init -q -b work "$PLAIN"
( cd "$PLAIN" && commit --allow-empty init )
out=$(cd "$PLAIN" && "$HOOK" definitely-not-a-real-branch 2>/dev/null); st=$?
check "an unresolved target exits 0" "0" "$st"
check "an unresolved target reports ok" "True" "$(field "$out" ok)"

# ── histories with no common ancestor degrade to a skip, not a warning ──
ORPHAN="$WORK/orphan"
git init -q -b work "$ORPHAN"
(
  cd "$ORPHAN" || exit 1
  printf 'base\n' > base.txt
  git add base.txt
  commit base
  git checkout -q --orphan target
  git rm -q -rf . >/dev/null 2>&1
  printf 'unrelated\n' > other.txt
  git add other.txt
  commit unrelated-root
  git checkout -q work
)
out=$(cd "$ORPHAN" && "$HOOK" target 2>/dev/null); st=$?
check "no common ancestor exits 0" "0" "$st"
check "no common ancestor degrades to ok:true" "True" "$(field "$out" ok)"
check "no common ancestor names no signals" "0" "$(signal_count "$out")"

# ── the decisive cheap layer: a target standing still carries no risk ──
UNMOVED="$WORK/unmoved"
git init -q -b work "$UNMOVED"
(
  cd "$UNMOVED" || exit 1
  printf 'base\n' > base.txt
  git add base.txt
  commit base
  git branch target
  printf '{"name":"app"}\n' > package.json
  git add package.json
  commit branch-touches-a-manifest
)
out=$(cd "$UNMOVED" && "$HOOK" target 2>/dev/null); st=$?
check "an unmoved target exits 0" "0" "$st"
check "an unmoved target reports ok:true" "True" "$(field "$out" ok)"
check "an unmoved target reports moved:0" "0" "$(field "$out" moved)"
check "an unmoved target raises no signal even on a touched manifest" "0" "$(signal_count "$out")"

# ── a moved target whose changes land nowhere risky ──
QUIET="$WORK/quiet"
diverged_repo "$QUIET" "src/feature.txt" "src/other.txt"
out=$(cd "$QUIET" && "$HOOK" target 2>/dev/null); st=$?
check "a quiet drift exits 0" "0" "$st"
check "a quiet drift reports ok:true" "True" "$(field "$out" ok)"
check "a quiet drift counts the target's commits" "1" "$(field "$out" moved)"
check "a quiet drift names no signals" "0" "$(signal_count "$out")"

expected_keys="moved,note,ok,signals"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

# ── a dependency manifest on the branch side alone is enough ──
DEP="$WORK/dep"
diverged_repo "$DEP" "pubspec.yaml" "lib/other.dart"
out=$(cd "$DEP" && "$HOOK" target 2>/dev/null); st=$?
check "a branch-side manifest exits 0" "0" "$st"
check "a branch-side manifest reports ok:false" "False" "$(field "$out" ok)"
check "a branch-side manifest is kind dependency" "dependency" "$(signal_kinds "$out")"
check "a branch-side manifest is sided to the branch" "branch" "$(side_of "$out" dependency)"

# ── a test-runner config on the target side alone is enough ──
TESTCFG="$WORK/testcfg"
diverged_repo "$TESTCFG" "src/feature.ts" "vitest.config.ts"
out=$(cd "$TESTCFG" && "$HOOK" target 2>/dev/null)
check "a target-side test config reports ok:false" "False" "$(field "$out" ok)"
check "a target-side test config is kind test-config" "test-config" "$(signal_kinds "$out")"
check "a target-side test config is sided to the target" "target" "$(side_of "$out" test-config)"

# ── one file touched by both sides is sided `both` ──
BOTH="$WORK/both"
git init -q -b work "$BOTH"
(
  cd "$BOTH" || exit 1
  printf '{"name":"app"}\n' > package.json
  git add package.json
  commit base
  git branch target
  printf '{"name":"app","branch":true}\n' > package.json
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -am branch-bump
  git checkout -q target
  printf '{"name":"app","target":true}\n' > package.json
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -am target-bump
  git checkout -q work
)
out=$(cd "$BOTH" && "$HOOK" target 2>/dev/null)
check "a manifest moved on both sides reports ok:false" "False" "$(field "$out" ok)"
check "a manifest moved on both sides is sided both" "both" "$(side_of "$out" dependency)"

# ── migrations need *both* sides: a version collision cannot happen alone ──
MIG_ONE="$WORK/mig-one"
diverged_repo "$MIG_ONE" "db/migrations/001_add_users.sql" "src/other.txt"
out=$(cd "$MIG_ONE" && "$HOOK" target 2>/dev/null)
check "a migration on one side alone stays quiet" "True" "$(field "$out" ok)"
check "a migration on one side alone raises no signal" "0" "$(signal_count "$out")"

# A file merely *named* for migration is not a migrations directory — the kind
# keys on the path segment, so `migrate.py` must not be mistaken for one.
MIG_NAMED="$WORK/mig-named"
diverged_repo "$MIG_NAMED" "tools/migrate.py" "tools/migrations.py"
out=$(cd "$MIG_NAMED" && "$HOOK" target 2>/dev/null)
check "a file merely named for migration stays quiet" "True" "$(field "$out" ok)"
check "a file merely named for migration raises no signal" "0" "$(signal_count "$out")"

MIG_BOTH="$WORK/mig-both"
diverged_repo "$MIG_BOTH" "db/migrations/001_add_users.sql" "db/migrations/002_add_orders.sql"
out=$(cd "$MIG_BOTH" && "$HOOK" target 2>/dev/null)
check "migrations on both sides report ok:false" "False" "$(field "$out" ok)"
check "migrations on both sides are kind migration" "migration" "$(signal_kinds "$out")"
check "migrations on both sides name every colliding file" "2" "$(signal_count "$out")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
