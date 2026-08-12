#!/bin/bash
# Offline tests for the headless-browser page-shot hook. Run from anywhere: bash feanor-shot.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/feanor-shot.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── missing arguments fail loud rather than rendering a blank ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no arguments at all exits 2" "2" "$st"

out=$("$HOOK" "http://example.test" 2>/dev/null); st=$?
check "missing out path exits 2" "2" "$st"

# ── a malformed viewport is caught before any render is attempted ──
out=$("$HOOK" "http://example.test" "$WORK/bad-viewport.png" "not-a-size" 2>/dev/null); st=$?
check "malformed viewport exits 2" "2" "$st"
check "malformed viewport writes no output file" "0" "$([[ -e "$WORK/bad-viewport.png" ]] && echo 1 || echo 0)"

# ── a stub standing in for Chrome/Edge, selected via FEANOR_BROWSER so the
# real absolute-path fallback (Applications / Program Files — unreachable from
# a sandboxed test run, and machine-dependent besides) is never consulted.
# That fallback branch (exit 3, "no headless browser found") is therefore not
# asserted here — it would either always pass or always fail depending on
# what happens to be installed on the machine running the suite, which is the
# opposite of what an offline test owes. ──
STUB_LOG="$WORK/invocations.log"
export STUB_LOG

write_stub() { # path body
  cat > "$1" <<STUB
#!/bin/bash
echo "\$*" >> "$STUB_LOG"
$2
STUB
  chmod +x "$1"
}

# ── the happy path: the modern --headless=new flag succeeds on the first
# try, the produced file is non-empty, and the hook echoes its path ──
HAPPY="$WORK/happy-browser.sh"
write_stub "$HAPPY" '
for a in "$@"; do
  case "$a" in
    --screenshot=*) printf "FAKE-PNG" > "${a#--screenshot=}" ;;
  esac
done
'
target="$WORK/happy.png"
out=$(FEANOR_BROWSER="$HAPPY" "$HOOK" "http://example.test/page" "$target" "1440x900"); st=$?
check "a working browser exits 0" "0" "$st"
check "a working browser prints the output path" "$target" "$out"
check "a working browser writes the image" "FAKE-PNG" "$(cat "$target" 2>/dev/null)"
check "the parsed viewport reaches the browser as --window-size=1440,900" "1" "$(grep -c -- '--window-size=1440,900' "$STUB_LOG")"
check "the page url reaches the browser as the final argument" "http://example.test/page" "$(tail -n1 "$STUB_LOG" | awk '{print $NF}')"

# ── the default viewport (1280x800) is used when none is given ──
: > "$STUB_LOG"
target="$WORK/default-viewport.png"
out=$(FEANOR_BROWSER="$HAPPY" "$HOOK" "http://example.test" "$target")
check "the default viewport reaches the browser as --window-size=1280,800" "1" "$(grep -c -- '--window-size=1280,800' "$STUB_LOG")"

# ── FEANOR_SETTLE_MS overrides the virtual-time-budget default ──
: > "$STUB_LOG"
target="$WORK/settle.png"
out=$(FEANOR_BROWSER="$HAPPY" FEANOR_SETTLE_MS=500 "$HOOK" "http://example.test" "$target")
check "FEANOR_SETTLE_MS overrides the virtual-time-budget default" "1" "$(grep -c -- '--virtual-time-budget=500' "$STUB_LOG")"

# ── the legacy-flag retry: a browser that ignores the modern --headless=new
# flag (writes nothing) but honours the legacy --headless is still a pass —
# this is the fallback shoot() exists to cover ──
: > "$STUB_LOG"
LEGACY_ONLY="$WORK/legacy-browser.sh"
write_stub "$LEGACY_ONLY" '
[ "$1" = "--headless=new" ] && exit 0
for a in "$@"; do
  case "$a" in
    --screenshot=*) printf "FAKE-PNG" > "${a#--screenshot=}" ;;
  esac
done
'
target="$WORK/legacy.png"
out=$(FEANOR_BROWSER="$LEGACY_ONLY" "$HOOK" "http://example.test" "$target"); st=$?
check "a browser answering only the legacy flag still exits 0" "0" "$st"
check "both the modern and legacy flags were tried, in that order" "--headless=new
--headless" "$(awk '{print $1}' "$STUB_LOG")"
check "the retry ultimately produces the image" "FAKE-PNG" "$(cat "$target" 2>/dev/null)"

# ── a browser that never produces a file fails loud (exit 4) rather than
# aligning a later pass to a blank image ──
SILENT="$WORK/silent-browser.sh"
write_stub "$SILENT" ': # writes nothing, whatever flags it is handed'
target="$WORK/silent.png"
out=$(FEANOR_BROWSER="$SILENT" "$HOOK" "http://example.test" "$target" 2>/dev/null); st=$?
check "a browser that renders nothing exits 4" "4" "$st"
check "a failed render leaves no output file behind" "0" "$([[ -e "$target" ]] && echo 1 || echo 0)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
