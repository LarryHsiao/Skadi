#!/bin/bash
# Offline tests for the Register scan. The contract: each conduct-grading word
# in the reply's own prose adds one line to ~/.skadi/register_log; the same word
# inside code, a blockquote or quotation marks adds nothing; the hook never
# prints and never fails, whatever it is handed.
# Run: bash register-scan.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/register-scan.py"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# scan <reply> — runs the hook on a Stop payload carrying <reply>, in a fresh
# home. Prints "<exit>|<stdout>|<logged words, comma-joined>".
scan() {
  local home out status words
  home="$(mktemp -d)"
  out=$(python3 -c 'import json,sys; print(json.dumps({"last_assistant_message":sys.argv[1]}))' "$1" \
    | HOME="$home" USERPROFILE="$home" python3 "$HOOK" 2>&1)
  status=$?
  words=$(logged "$home")
  rm -rf "$home"
  echo "$status|$out|$words"
}

# raw <stdin text> — same, with the payload given verbatim.
raw() {
  local home out status words
  home="$(mktemp -d)"
  out=$(printf '%s' "$1" | HOME="$home" USERPROFILE="$home" python3 "$HOOK" 2>&1)
  status=$?
  words=$(logged "$home")
  rm -rf "$home"
  echo "$status|$out|$words"
}

logged() { # home — the word column of the log, comma-joined; empty when no log
  [ -f "$1/.skadi/register_log" ] || return 0
  cut -f2 "$1/.skadi/register_log" | paste -sd, -
}

# ── 1 · a Chinese grading word in plain prose is logged once ──
expected_zh="0||忘了"
actual_zh=$(scan "你忘了檢查 user 是否為空。")
check "Chinese word in prose logs one line" "$expected_zh" "$actual_zh"

# ── 2 · an English one is logged whatever its case ──
expected_en="0||forgot"
actual_en=$(scan "Forgot to handle the timeout in fetch().")
check "English word in prose logs one line, case ignored" "$expected_en" "$actual_en"

# ── 3 · every occurrence earns its own line ──
expected_two="0||failed to,疏忽"
actual_two=$(scan "The team failed to notice it. 這是疏忽。")
check "two words log two lines, in reading order" "$expected_two" "$actual_two"

# ── 4 · the log line carries the date and a snippet beside the word ──
expected_cols="3"
home_cols="$(mktemp -d)"
python3 -c 'import json; print(json.dumps({"last_assistant_message":"這裡早該處理。"}))' \
  | HOME="$home_cols" USERPROFILE="$home_cols" python3 "$HOOK"
actual_cols=$(awk -F'\t' 'NR==1 && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $3 ~ /早該處理/ {print NF}' \
  "$home_cols/.skadi/register_log" 2>/dev/null)
rm -rf "$home_cols"
check "log line is date, word, snippet" "$expected_cols" "$actual_cols"

# ── 5 · quoted and shown text is not the reply's own voice ──
expected_none="0||"
actual_span=$(scan 'The rule drops `forgot` and `早該` from a sentence.')
check "word inside a code span logs nothing" "$expected_none" "$actual_span"

actual_fence=$(scan $'Draft:\n```\nYou forgot the null check.\n```\nDone.')
check "word inside a fenced block logs nothing" "$expected_none" "$actual_fence"

actual_quote=$(scan $'Summary.\n> **Grammar:** "you forgot it" → "you **forgot** it"')
check "word inside a blockquote logs nothing" "$expected_none" "$actual_quote"

actual_marks=$(scan 'The draft said "you forgot it" and 「這裡早該處理」, both removed.')
check "word inside quotation marks logs nothing" "$expected_none" "$actual_marks"

actual_tilde=$(scan $'Draft:\n~~~\nYou forgot the null check.\n~~~\nDone.')
check "word inside a tilde fence logs nothing" "$expected_none" "$actual_tilde"

actual_curly=$(scan 'The draft said “you forgot it” and 『這裡早該處理』, both removed.')
check "word inside curly or double corner quotes logs nothing" "$expected_none" "$actual_curly"

# ── 5b · marks that only look like quoting do not hide the prose between them ──
expected_inch="0||forgot"
actual_inch=$(scan 'The 5" pipe, and you forgot the cap, a 6" one.')
check "inch marks do not pair up into a quotation" "$expected_inch" "$actual_inch"

expected_nested="0||"
actual_nested=$(scan $'````\n```\nYou forgot it.\n```\nand it was careless.\n````\nDone.')
check "a longer fence holds a shorter one whole" "$expected_nested" "$actual_nested"

expected_wrapped="0||should have"
actual_wrapped=$(scan $'This should\nhave been tested.')
check "a two-word entry split across a line break still logs, as one word" "$expected_wrapped" "$actual_wrapped"

# ── 5c · only the listed words count, whole ──
expected_inflected="0||"
actual_inflected=$(scan "The timeout was forgotten and handled carelessly.")
check "an inflected form of a listed word logs nothing" "$expected_inflected" "$actual_inflected"

expected_whole="0||forgot,careless"
actual_whole=$(scan "You forgot it, and that was careless.")
check "the listed words themselves still log" "$expected_whole" "$actual_whole"

expected_cjk="0||forgot"
actual_cjk=$(scan "這裡你forgot了。")
check "a listed word set against Chinese text still logs" "$expected_cjk" "$actual_cjk"

expected_cjk_quote="0||"
actual_cjk_quote=$(scan '草稿寫著"你忘了檢查"，已移除。')
check "a quotation set against Chinese text is still a quotation" "$expected_cjk_quote" "$actual_cjk_quote"

# ── 5d · a closed fence ends at its closing line ──
expected_after="0||forgot"
actual_after=$(scan $'a\n```\nx\n```\nyou forgot')
check "prose after a closed fence is still scanned" "$expected_after" "$actual_after"

expected_between="0||forgot,careless"
actual_between=$(scan $'a\n```\nx\n```\nyou forgot\n```\ny\n```\nand careless')
check "prose between and after two closed fences is scanned" "$expected_between" "$actual_between"

# ── 5e · a fence left open shows everything after it ──
expected_open="0||忘了"
actual_open=$(scan $'這裡忘了。\n```\nYou forgot the null check.\nand it was careless.')
check "text after an unclosed fence logs nothing; text before it still does" "$expected_open" "$actual_open"

# ── 6 · a clean reply leaves no log behind ──
actual_clean=$(scan "login.dart:42 throws when user is null; it needs a null check.")
check "clean reply logs nothing" "$expected_none" "$actual_clean"

# ── 7 · trouble in the payload ends quietly ──
actual_empty=$(raw "")
check "empty input exits 0 and logs nothing" "$expected_none" "$actual_empty"

actual_bad=$(raw "{not json")
check "malformed input exits 0 and logs nothing" "$expected_none" "$actual_bad"

actual_nofield=$(raw '{"session_id":"x"}')
check "payload without a reply exits 0 and logs nothing" "$expected_none" "$actual_nofield"

actual_list=$(raw '[1,2]')
check "payload that is not an object exits 0 and logs nothing" "$expected_none" "$actual_list"

# ── 8 · a log that cannot be written is swallowed ──
expected_unwritable="0|"
home_blocked="$(mktemp -d)"
: > "$home_blocked/.skadi"   # a file where the log's folder should be
out_blocked=$(python3 -c 'import json; print(json.dumps({"last_assistant_message":"你忘了檢查。"}))' \
  | HOME="$home_blocked" USERPROFILE="$home_blocked" python3 "$HOOK" 2>&1)
actual_unwritable="$?|$out_blocked"
rm -rf "$home_blocked"
check "unwritable log exits 0 and prints nothing" "$expected_unwritable" "$actual_unwritable"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
