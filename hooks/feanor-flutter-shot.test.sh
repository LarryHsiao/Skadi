#!/bin/bash
# Offline tests for the Flutter-device screenshot hook. Run from anywhere: bash feanor-flutter-shot.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/feanor-flutter-shot.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# A narrow PATH that keeps the core utilities the hook itself leans on
# (mktemp, tail, sed, tr) but excludes wherever this machine's real flutter
# or fvm happen to live — so "neither is installed" below is a deterministic
# branch, not a bet on this developer's own toolchain.
BARE_PATH="$WORK/bin:/usr/bin:/bin"

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

# ── a missing output path fails loud before any flutter command runs ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no arguments at all exits 2" "2" "$st"

# ── neither flutter nor fvm on PATH ──
out=$(PATH="$BARE_PATH" "$HOOK" "$WORK/no-tool.png" 2>/dev/null); st=$?
check "no flutter and no fvm on PATH exits 3" "3" "$st"

# ── a `flutter` directly on PATH takes the screenshot ──
: > "$STUB_LOG"
write_stub "$WORK/bin/flutter" '
if [ "$1" = "screenshot" ]; then
  for a in "$@"; do
    case "$a" in
      --out=*) printf "FAKE-PNG" > "${a#--out=}" ;;
    esac
  done
fi
'
target="$WORK/plain.png"
out=$(PATH="$BARE_PATH" "$HOOK" "$target" 2>/dev/null); st=$?
check "a working flutter on PATH exits 0" "0" "$st"
check "a working flutter prints the output path" "$target" "$out"
check "a working flutter writes the screenshot" "FAKE-PNG" "$(cat "$target" 2>/dev/null)"
check "no -d flag is sent when no deviceId is given" "0" "$(grep -c -- ' -d ' "$STUB_LOG")"

# ── a deviceId is forwarded as `-d <id>` ──
: > "$STUB_LOG"
target="$WORK/device.png"
out=$(PATH="$BARE_PATH" "$HOOK" "$target" "emulator-5554" 2>/dev/null); st=$?
check "a deviceId still exits 0" "0" "$st"
check "the deviceId reaches flutter as -d <id>" "1" "$(grep -c -- '-d emulator-5554' "$STUB_LOG")"

# ── flutter absent from PATH, but fvm present: the documented fallback,
# invoked as the two-word `fvm flutter` per the hook's own comment ──
rm -f "$WORK/bin/flutter"
: > "$STUB_LOG"
write_stub "$WORK/bin/fvm" '
if [ "$1" = "flutter" ] && [ "$2" = "screenshot" ]; then
  for a in "$@"; do
    case "$a" in
      --out=*) printf "FAKE-PNG" > "${a#--out=}" ;;
    esac
  done
fi
'
target="$WORK/fvm.png"
out=$(PATH="$BARE_PATH" "$HOOK" "$target" 2>/dev/null); st=$?
check "the fvm-flutter fallback exits 0" "0" "$st"
check "the fvm-flutter fallback writes the screenshot" "FAKE-PNG" "$(cat "$target" 2>/dev/null)"

# ── a real but unready flutter (no booted device) surfaces its own stderr,
# so the failure reads as flutter's own explanation, not a bare hook error ──
write_stub "$WORK/bin/flutter" '
echo "Error: No connected devices." >&2
'
target="$WORK/none.png"
out=$(PATH="$BARE_PATH" "$HOOK" "$target" 2>"$WORK/stderr.txt"); st=$?
check "an unready device exits 4" "4" "$st"
check "no screenshot file is left behind" "0" "$([[ -e "$target" ]] && echo 1 || echo 0)"
check "flutter's own stderr is surfaced" "1" "$(grep -c "No connected devices" "$WORK/stderr.txt")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
