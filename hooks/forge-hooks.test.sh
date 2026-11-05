#!/usr/bin/env bash
# Test for forge-github-pr.sh and forge-gitlab-mr.sh. Run by hand: hooks/forge-hooks.test.sh
# Offline: a throwaway repo with a bare local origin, and stub `gh` / `glab` on PATH.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# --- stubs -----------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
CALLS="$WORK/calls.log"

cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list") [ -n "${FAKE_EXISTING_URL:-}" ] && echo "$FAKE_EXISTING_URL"; exit 0 ;;
  "pr create") echo "https://github.com/o/r/pull/7"; exit 0 ;;
esac
exit 1
EOF

cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
  "mr list")
    if [ -n "${FAKE_EXISTING_URL:-}" ]; then
      printf '[{"web_url":"%s"}]\n' "$FAKE_EXISTING_URL"
    else
      echo '[]'
    fi
    exit 0 ;;
  "mr create") echo "https://gitlab.com/o/r/-/merge_requests/7"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBS/gh" "$STUBS/glab"

# --- repo ------------------------------------------------------------------
new_repo() {
  rm -rf "$WORK/origin.git" "$WORK/repo"
  git init -q --bare "$WORK/origin.git"
  git init -q -b main "$WORK/repo"
  git -C "$WORK/repo" config user.email t@example.com
  git -C "$WORK/repo" config user.name t
  git -C "$WORK/repo" config commit.gpgsign false
  git -C "$WORK/repo" remote add origin "$WORK/origin.git"
  git -C "$WORK/repo" commit -q --allow-empty -m base
  git -C "$WORK/repo" checkout -q -b KEY-1/feat/x
  : > "$CALLS"
}

run_hook() {
  local hook="$1"
  (cd "$WORK/repo" && printf 'body\n' | PATH="$STUBS:$PATH" CALLS="$CALLS" \
    FAKE_EXISTING_URL="${FAKE_EXISTING_URL:-}" "$HERE/$hook" KEY-1/feat/x main "[KEY-1] feat: x" --draft)
}

pushed() { git -C "$WORK/origin.git" rev-parse --verify -q refs/heads/KEY-1/feat/x >/dev/null && echo yes || echo no; }
created() { grep -cE '^(gh pr create|glab mr create)' "$CALLS"; }

for spec in "forge-github-pr.sh github" "forge-gitlab-mr.sh gitlab"; do
  read -r hook forge <<< "$spec"

  # 1. No commits ahead of the base -> skipped, nothing pushed, nothing created.
  new_repo
  out=$(run_hook "$hook"); code=$?
  expected="skipped: forge=$forge reason=no-commits"
  check "$forge no commits -> exit 0" "0" "$code"
  check "$forge no commits -> skipped line" "$expected" "$out"
  check "$forge no commits -> branch not pushed" "no" "$(pushed)"
  check "$forge no commits -> nothing created" "0" "$(created)"

  # 2. Commits ahead, no PR/MR yet -> opened.
  new_repo
  git -C "$WORK/repo" commit -q --allow-empty -m work
  out=$(run_hook "$hook"); code=$?
  expected="opened: forge=$forge url=$(printf '%s' "$out" | grep -Eo 'https?://[^ ]+') number=7"
  check "$forge commits, no PR -> exit 0" "0" "$code"
  check "$forge commits, no PR -> opened line" "$expected" "$out"
  check "$forge commits, no PR -> created once" "1" "$(created)"

  # 3. Commits ahead, PR/MR already open -> exists, nothing new created.
  new_repo
  git -C "$WORK/repo" commit -q --allow-empty -m work
  existing="https://example.test/existing/1"
  out=$(FAKE_EXISTING_URL="$existing" run_hook "$hook"); code=$?
  expected="exists: forge=$forge url=$existing"
  check "$forge existing PR -> exit 0" "0" "$code"
  check "$forge existing PR -> exists line" "$expected" "$out"
  check "$forge existing PR -> nothing created" "0" "$(created)"
done

exit $fail
