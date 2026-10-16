#!/bin/bash
# Offline tests for the ink-centre hook. Run from anywhere: bash feanor-ink-centre.test.sh
# The measuring cases draw real PNGs with ImageMagick and are skipped (named, not
# silently) when it is absent; the argument and not-found cases need nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/feanor-ink-centre.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE_IMG="$WORK/fake.png"
printf 'FAKE-PNG' > "$FAKE_IMG"

# ── missing or malformed arguments fail loud rather than measuring garbage ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no arguments at all exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 5 2>/dev/null); st=$?
check "a missing x1 exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 5 wide 2>/dev/null); st=$?
check "a non-numeric x1 exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 25 5 2>/dev/null); st=$?
check "an x1 not past x0 exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 5 25 10 2>/dev/null); st=$?
check "a y0 without a y1 exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 5 25 "" 40 2>/dev/null); st=$?
check "a y1 without a y0 exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 5 25 30 10 2>/dev/null); st=$?
check "a y1 not past y0 exits 2" "2" "$st"

# ── no ImageMagick on a narrow PATH (Homebrew's lives outside /usr/bin:/bin) ──
out=$(PATH="/usr/bin:/bin" FEANOR_MAGICK="" "$HOOK" "$FAKE_IMG" 5 25 2>/dev/null); st=$?
check "no ImageMagick on PATH exits 3" "3" "$st"

if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  echo "  skip · measuring cases — ImageMagick not installed on this machine"
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit
fi
im="$(command -v magick || command -v convert)"

# A white canvas bearing: a black square (rows 20-29) under x 10-19; a 54%-black
# bar (rgb 117 — Material's action.active on white) at rows 30-45 under x 50-59;
# and a light-grey bar (rgb 200, RGB sum 600) under x 80-89, below the ink line.
SHOT="$WORK/shot.png"
"$im" -size 100x60 xc:white \
  -fill black -draw "rectangle 10,20 19,29" \
  -fill "rgb(117,117,117)" -draw "rectangle 50,30 59,45" \
  -fill "rgb(200,200,200)" -draw "rectangle 80,5 89,15" "$SHOT"

expected="x 5-25: rows 20-29, centre 24.5"
out=$("$HOOK" "$SHOT" 5 25); st=$?
check "a black square exits 0" "0" "$st"
check "a black square reports its ink rows and centre" "$expected" "$out"

expected="x 45-65: rows 30-45, centre 37.5"
out=$("$HOOK" "$SHOT" 45 65)
check "a 54%-black bar counts as ink" "$expected" "$out"

expected="x 5-25: rows 22-29, centre 25.5"
out=$("$HOOK" "$SHOT" 5 25 22 60)
check "a y range clips the scan and rows stay in image coordinates" "$expected" "$out"

out=$("$HOOK" "$SHOT" 75 95 2>/dev/null); st=$?
check "light grey below the ink line measures nothing and exits 4" "4" "$st"

out=$("$HOOK" "$SHOT" 5 25 35 60 2>/dev/null); st=$?
check "a y range holding no ink exits 4" "4" "$st"

expected="x 75-95: rows 5-15, centre 10.0"
out=$(FEANOR_INK_SUM=700 "$HOOK" "$SHOT" 75 95)
check "a raised FEANOR_INK_SUM lets light grey count" "$expected" "$out"

out=$(FEANOR_INK_SUM=many "$HOOK" "$SHOT" 75 95 2>/dev/null); st=$?
check "a non-numeric FEANOR_INK_SUM exits 2" "2" "$st"

# ── transparency is flattened onto white: a transparent pixel stores rgb 0,0,0
# and would otherwise read as the darkest ink of all ──
CLEAR="$WORK/clear.png"
"$im" -size 100x60 xc:none -fill black -draw "rectangle 10,20 19,29" "$CLEAR"
out=$("$HOOK" "$CLEAR" 40 60 2>/dev/null); st=$?
check "a fully transparent region is not ink and exits 4" "4" "$st"

expected="x 5-25: rows 20-29, centre 24.5"
out=$("$HOOK" "$CLEAR" 5 25)
check "opaque ink on a transparent canvas still measures" "$expected" "$out"

out=$("$HOOK" "$SHOT" 200 220 2>/dev/null); st=$?
check "a span outside the image exits 4" "4" "$st"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
