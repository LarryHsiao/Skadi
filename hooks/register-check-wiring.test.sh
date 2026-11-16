#!/bin/bash
# Tests that the posting hooks run register-check.py on a body before sending
# it. One poster is driven end to end with a stub `gh`, to prove a refused body
# reaches no network call; the rest are held by a reading of their source, so a
# poster added later without the check fails here.
# Run: bash register-check-wiring.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · end to end: mithrandir-github-comment.sh behind a stub gh ──
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
CALLS="$STUB_DIR/calls"
cat > "$STUB_DIR/gh" <<'STUB'
#!/bin/bash
# Records every invocation; `auth status` and `pr comment` both succeed.
printf '%s\n' "$1 $2" >> "$GH_CALLS"
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# post <body> — "<exit>|<every gh call made, comma-joined>|<first word of stdout>"
post() {
  local out status sent
  : > "$CALLS"
  out=$(printf '%s' "$1" | GH_CALLS="$CALLS" PATH="$STUB_DIR:$PATH" \
    "$HERE/mithrandir-github-comment.sh" "https://github.com/acme/widget/pull/7" 2>/dev/null)
  status=$?
  sent=$(paste -sd, - < "$CALLS")
  echo "$status|$sent|${out%% *}"
}

expected_refused='1|auth status|{"error":'
actual_refused=$(post "你忘了檢查 user 是否為空。")
check "a grading body is refused and gh is asked nothing past auth" "$expected_refused" "$actual_refused"

expected_sent='0|auth status,pr comment|commented:'
actual_sent=$(post "login.dart:42 在 user 為空時會拋例外，需要空值檢查。")
check "a clean body is posted once" "$expected_sent" "$actual_sent"

# ── 2 · every poster runs the check on the body it is about to send ──
# A poster is any hook that normalises a body with body-to-utf8.sh, plus the
# two reply hooks that read a body without it. Name a new one here if it takes
# its body some third way.
EXTRA_POSTERS="narvi-github-reply.sh narvi-gitlab-reply.sh"
posters=$( { grep -l 'body-to-utf8\.sh" "\$body_file"' "$HERE"/*.sh | xargs -n1 basename; \
             printf '%s\n' $EXTRA_POSTERS; } | grep -v '\.test\.sh$' | sort -u)

expected_unchecked=""
actual_unchecked=$(for poster in $posters; do
  grep -q '^python -I "\$(dirname "\$0")/register-check\.py" "\$body_file"' "$HERE/$poster" || printf '%s ' "$poster"
done)
check "no poster sends a body unchecked" "$expected_unchecked" "$actual_unchecked"

# The check must come after the encoding fix it relies on, and carry its label.
expected_misplaced=""
actual_misplaced=$(for poster in $posters; do
  awk -v name="$poster" '
    /body-to-utf8\.sh" "\$body_file"/ { want = "python -I " $0; sub(/body-to-utf8\.sh/, "register-check.py", want); armed = 1; next }
    armed { if ($0 != want) printf "%s ", name; armed = 0 }
  ' "$HERE/$poster"
done)
check "the check follows body-to-utf8.sh with the same file and label" "$expected_misplaced" "$actual_misplaced"

# A tripwire, not a limit: a correctly wired twelfth poster fails here until
# the number is raised, which is the moment to confirm it was wired on purpose.
expected_count="11"
actual_count=$(printf '%s\n' $posters | wc -l | tr -d ' ')
check "the poster list holds the eleven known posters" "$expected_count" "$actual_count"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
