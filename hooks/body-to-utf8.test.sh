#!/usr/bin/env bash
# Test for body-to-utf8.sh. Run by hand: hooks/body-to-utf8.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/body-to-utf8.sh"
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

# 1. Valid UTF-8 with a 3-byte character across byte 1024 -> untouched, exit 0.
python3 -c "import sys; sys.stdout.buffer.write(('a' * 1022 + '中' * 200).encode())" > "$WORK/a"
cp "$WORK/a" "$WORK/a.orig"
"$SCRIPT" "$WORK/a"; code=$?
check "UTF-8 across byte 1024 -> exit 0" "0" "$code"
check "UTF-8 across byte 1024 -> bytes unchanged" "0" "$(cmp -s "$WORK/a" "$WORK/a.orig"; echo $?)"

# 2. CP1252 curly quotes (0x93 0x94) -> rewritten as UTF-8.
printf 'say \x93hi\x94' > "$WORK/b"
"$SCRIPT" "$WORK/b"; code=$?
expected_text='say “hi”'
check "CP1252 -> exit 0" "0" "$code"
check "CP1252 -> converted to UTF-8" "$expected_text" "$(cat "$WORK/b")"

# 3. Neither (0x81 is undefined in CP1252, invalid as UTF-8) -> exit 1 with JSON error.
printf 'bad \x81 byte' > "$WORK/c"
out=$("$SCRIPT" "$WORK/c"); code=$?
expected_error='{"error":"comment body is neither valid UTF-8 nor CP1252"}'
check "neither -> exit 1" "1" "$code"
check "neither -> default label in error" "$expected_error" "$out"

# 4. A label names the body in the error.
out=$("$SCRIPT" "$WORK/c" MR); code=$?
expected_error='{"error":"MR body is neither valid UTF-8 nor CP1252"}'
check "label -> named in error" "$expected_error" "$out"

exit $fail
