#!/bin/bash
# Offline tests for the Orthanc copy-marker scan. The contract: a Stop payload
# whose reply holds a pasteable fence (shell or markdown) without a
# `⧉ copy:<name>` line directly above it, or whose marker names a file that
# was never written, is blocked with a reason naming the fence; every other
# reply passes with no output; a second stop in a row is never blocked.
# Run: bash orthanc-copy-scan.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/orthanc-copy-scan.py"
pass=0
fail=0
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
: >"$DIR/block-1.sh"

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# scan <reply> [active] — runs the hook on a Stop payload. Prints
# "<exit>|<decision or empty>".
scan() {
  local out status
  out=$(python3 -c 'import json,sys; print(json.dumps({"last_assistant_message":sys.argv[1],"stop_hook_active":sys.argv[2]=="1"}))' "$1" "${2:-0}" \
    | ORTHANC_COPY_DIR="$DIR" python3 "$HOOK" 2>&1)
  status=$?
  echo "$status|$(printf '%s' "$out" | python3 -c 'import json,sys
t=sys.stdin.read()
print(json.loads(t)["decision"] if t.strip() else "")')"
}

FENCE='```'
unmarked="Run this:
${FENCE}bash
git status
${FENCE}"
marked="Run this:
⧉ copy:block-1.sh
${FENCE}bash
git status
${FENCE}"
nofile="⧉ copy:missing.sh
${FENCE}bash
git status
${FENCE}"
spaced="⧉ copy:block-1.sh

${FENCE}bash
git status
${FENCE}"

expected="0|block"
check "an unmarked bash fence is blocked" "$expected" "$(scan "$unmarked")"
check "an unmarked markdown fence is blocked" "$expected" "$(scan "${FENCE}markdown
## Note
${FENCE}")"
check "a marker whose file is missing is blocked" "$expected" "$(scan "$nofile")"
check "a marker separated from its fence by a blank line is blocked" "$expected" "$(scan "$spaced")"
check "one marked and one unmarked fence is blocked" "$expected" "$(scan "$marked
$unmarked")"

expected="0|"
check "a marked fence with its file present passes" "$expected" "$(scan "$marked")"
check "a dart fence passes" "$expected" "$(scan "${FENCE}dart
void main() {}
${FENCE}")"
check "an untagged fence passes (gate and Done blocks use them)" "$expected" "$(scan "${FENCE}
Size minimum
${FENCE}")"
check "an inline code span passes" "$expected" "$(scan 'run `git status` now')"
check "a reply with no fence passes" "$expected" "$(scan "plain prose")"
check "an unmarked fence on a second stop in a row passes" "$expected" "$(scan "$unmarked" 1)"
check "a bash fence inside a longer fence is not scanned" "$expected" "$(scan "${FENCE}${FENCE}text
${FENCE}bash
x
${FENCE}
${FENCE}${FENCE}")"
crlf="⧉ copy:block-1.sh"$'\r\n'"${FENCE}bash"$'\r\n'"git status"$'\r\n'"${FENCE}"$'\r\n'
check "a marked fence in a CRLF reply passes" "$expected" "$(scan "$crlf")"
check "an unmarked tilde fence is blocked" "0|block" "$(scan "~~~bash
git status
~~~")"
check "an unclosed unmarked bash fence is blocked" "0|block" "$(scan "${FENCE}bash
git status")"

raw() { printf '%s' "$1" | ORTHANC_COPY_DIR="$DIR" python3 "$HOOK" 2>&1; echo "$?"; }
expected="0"
check "a payload that is not JSON passes silently" "$expected" "$(raw 'nope')"
check "a payload without a reply passes silently" "$expected" "$(raw '{}')"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
