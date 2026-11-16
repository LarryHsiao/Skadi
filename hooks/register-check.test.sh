#!/bin/bash
# Offline tests for the Register check that posting hooks run on a body before
# they send it. The contract: a body whose own prose holds a conduct-grading
# word is refused with exit 1 and a JSON error naming the word and its
# sentence; any other body passes silently; nothing is written to the log; a
# body that cannot be read is let through so a broken check never stops a post.
# Run: bash register-check.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/register-check.py"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# verdict <body> [label] — "<exit>|<error text, or empty>|<log written yes|no>"
verdict() {
  local home file out status error wrote
  home="$(mktemp -d)"
  file="$home/body.md"
  printf '%s' "$1" > "$file"
  out=$(HOME="$home" USERPROFILE="$home" python -I "$CHECK" "$file" ${2:+"$2"} 2>/dev/null)
  status=$?
  error=$(printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
print(json.loads(raw)["error"] if raw else "")')
  wrote=no; [ -e "$home/.skadi" ] && wrote=yes
  rm -rf "$home"
  echo "$status|$error|$wrote"
}

GUIDE='Describe the thing, not the person, then post again. Text you are quoting belongs in quotation marks or a code span.'

# ── 1 · a grading word in the body's own prose refuses the post ──
expected_zh="1|comment body grades a person's conduct: 「忘了」 in 「你忘了檢查 user 是否為空。」. $GUIDE|no"
actual_zh=$(verdict "你忘了檢查 user 是否為空。")
check "Chinese word in prose is refused, naming word and sentence" "$expected_zh" "$actual_zh"

# ── 2 · the label names which body it was ──
expected_label="1|PR body grades a person's conduct: 「forgot」 in 「You forgot the null check.」. $GUIDE|no"
actual_label=$(verdict "You forgot the null check." PR)
check "label replaces the default body name" "$expected_label" "$actual_label"

# ── 3 · every hit is named ──
expected_two="1|comment body grades a person's conduct: 「failed to」 in 「The team failed to notice it. 這是疏忽。」; 「疏忽」 in 「led to notice it. 這是疏忽。」. $GUIDE|no"
actual_two=$(verdict "The team failed to notice it. 這是疏忽。")
check "two words are both named" "$expected_two" "$actual_two"

# ── 4 · quoted and shown text passes ──
expected_pass="0||no"
actual_span=$(verdict 'The rule drops `forgot` and `早該` from a sentence.')
check "word inside a code span passes" "$expected_pass" "$actual_span"

actual_fence=$(verdict $'Draft:\n```\nYou forgot the null check.\n```\nDone.')
check "word inside a fenced block passes" "$expected_pass" "$actual_fence"

actual_quote=$(verdict $'Earlier note:\n> you forgot it\n\nNow fixed.')
check "word inside a blockquote passes" "$expected_pass" "$actual_quote"

actual_marks=$(verdict 'The draft said "you forgot it" and 「這裡早該處理」, both removed.')
check "word inside quotation marks passes" "$expected_pass" "$actual_marks"

# ── 5 · a clean body passes ──
actual_clean=$(verdict "login.dart:42 throws when user is null; it needs a null check.")
check "clean body passes" "$expected_pass" "$actual_clean"

# ── 6 · a body that cannot be read is let through ──
expected_missing="0|"
out_missing=$(python -I "$CHECK" "/nonexistent/body.md" 2>/dev/null)
actual_missing="$?|$out_missing"
check "missing body file passes with nothing on stdout" "$expected_missing" "$actual_missing"

expected_binary="0|"
bin_dir="$(mktemp -d)"
printf '\xff\xfe\x00bad' > "$bin_dir/body.md"
out_binary=$(python -I "$CHECK" "$bin_dir/body.md" 2>/dev/null)
actual_binary="$?|$out_binary"
rm -rf "$bin_dir"
check "body that is not UTF-8 passes with nothing on stdout" "$expected_binary" "$actual_binary"

# ── 7 · a call with no file is a wiring fault, and says so ──
expected_usage='1|{"error": "usage: register-check.py <body-file> [label]"}'
out_usage=$(python -I "$CHECK" 2>/dev/null)
actual_usage="$?|$out_usage"
check "no argument exits 1 with a usage error" "$expected_usage" "$actual_usage"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
