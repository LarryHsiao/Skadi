#!/bin/bash
# Offline tests for the scanline run-measuring hook. Run from anywhere: bash feanor-measure.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/feanor-measure.sh"
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

# ── missing or malformed arguments fail loud rather than scanning garbage ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no arguments at all exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" row 2>/dev/null); st=$?
check "missing index exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" diagonal 10 2>/dev/null); st=$?
check "an axis that is neither row nor col exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" row "not-a-number" 2>/dev/null); st=$?
check "non-numeric index exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" row 10 "loose" 2>/dev/null); st=$?
check "non-numeric tolerance exits 2" "2" "$st"

# ── ImageMagick's "not found" branch depends on what happens to be installed on
# the machine running the suite (the same reasoning feanor-shot.test.sh gives for
# skipping its browser-not-found branch) — not asserted here for the same reason. ──

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

# Every stub answers the crop call by writing the named file, and the txt: call
# by printing whatever enumeration the test set in \$STUB_PIXELS.
STUB_BODY='
has_crop=0
for a in "$@"; do
  last="$a"
  case "$a" in
    -crop) has_crop=1 ;;
  esac
done
if [ "$has_crop" = "1" ]; then
  printf "FAKE-LINE" > "$last"
  exit 0
fi
case "$*" in
  *"txt:"*) printf "%s\n" "# ImageMagick pixel enumeration" ; cat "$STUB_PIXELS" ;;
esac
'
MAGICK="$WORK/magick.sh"
write_stub "$MAGICK" "$STUB_BODY"
export STUB_PIXELS="$WORK/pixels.txt"

# ── a row scan: coordinates vary in x, and adjacent like-coloured pixels
# collapse into one run reported as start/end/length/hex ──
cat > "$STUB_PIXELS" <<'PIX'
0,0: (234,243,245) #EAF3F5 srgb(234,243,245)
1,0: (234,243,245) #EAF3F5 srgb(234,243,245)
2,0: (255,255,255) #FFFFFF white
3,0: (255,255,255) #FFFFFF white
4,0: (255,255,255) #FFFFFF white
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 7); st=$?
check "a row scan exits 0" "0" "$st"
check "a row scan reports runs as start/end/length/hex" "0 1 2 #EAF3F5
2 4 3 #FFFFFF" "$out"
check "a row scan crops one pixel tall at the given y" "1" "$(grep -c -- '-crop x1+0+7' "$STUB_LOG")"

# ── a column scan: the varying coordinate is y, not x, and the crop is one
# pixel wide at the given x ──
: > "$STUB_LOG"
cat > "$STUB_PIXELS" <<'PIX'
0,0: (234,243,245) #EAF3F5 srgb(234,243,245)
0,1: (234,243,245) #EAF3F5 srgb(234,243,245)
0,2: (237,108,2) #ED6C02 srgb(237,108,2)
0,3: (237,108,2) #ED6C02 srgb(237,108,2)
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" col 12)
check "a column scan measures along y, not x" "0 1 2 #EAF3F5
2 3 2 #ED6C02" "$out"
check "a column scan crops one pixel wide at the given x" "1" "$(grep -c -- '-crop 1x+12+0' "$STUB_LOG")"

# ── a one-pixel anti-aliasing sliver between two real regions is dropped by the
# default minimum run length, so boundaries read off the surviving runs ──
cat > "$STUB_PIXELS" <<'PIX'
0,0: (255,255,255) #FFFFFF white
1,0: (255,255,255) #FFFFFF white
2,0: (146,181,123) #92B57B srgb(146,181,123)
3,0: (37,107,0) #256B00 srgb(37,107,0)
4,0: (37,107,0) #256B00 srgb(37,107,0)
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0)
check "a single-pixel blend band is dropped at the default min-run" "0 1 2 #FFFFFF
3 4 2 #256B00" "$out"

# ── the same sliver survives when min-run is lowered to 1, proving it was the
# filter that dropped it rather than the run grouping losing it ──
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0 8 1)
check "min-run 1 keeps the blend band as its own run" "0 1 2 #FFFFFF
2 2 1 #92B57B
3 4 2 #256B00" "$out"

# ── tolerance holds a run together across imperceptible drift, and the run is
# reported in the colour it STARTED on ──
cat > "$STUB_PIXELS" <<'PIX'
0,0: (255,255,255) #FFFFFF white
1,0: (251,252,255) #FBFCFF srgb(251,252,255)
2,0: (250,250,250) #FAFAFA srgb(250,250,250)
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0)
check "near-identical pixels group into one run under the default tolerance" "0 2 3 #FFFFFF" "$out"

# ── the same pixels split once the tolerance is tightened below their drift ──
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0 1 1)
check "a tightened tolerance splits the same pixels" "0 0 1 #FFFFFF
1 1 1 #FBFCFF
2 2 1 #FAFAFA" "$out"

# ── a gradient stepping 5 per pixel under a tolerance of 8 separates the two
# possible grouping rules: measured against each run's STARTING colour it breaks
# once cumulative drift passes the tolerance, while measured against the
# PREVIOUS pixel no step ever exceeds it and the whole gradient collapses into
# one run. The documented rule is start-colour, so a gradient must not drift
# silently into a single region. ──
cat > "$STUB_PIXELS" <<'PIX'
0,0: (100,100,100) #646464 srgb(100,100,100)
1,0: (105,105,105) #696969 srgb(105,105,105)
2,0: (110,110,110) #6E6E6E srgb(110,110,110)
3,0: (115,115,115) #737373 srgb(115,115,115)
4,0: (120,120,120) #787878 srgb(120,120,120)
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0)
check "a gradient breaks into runs rather than drifting into one" "0 1 2 #646464
2 3 2 #6E6E6E" "$out"

# ── a crop that writes no file at all fails loud rather than reporting an empty
# measurement as a clean one. (A real out-of-bounds index does NOT reach this
# branch — ImageMagick writes a tiny greyscale file instead, which falls to the
# no-runs exit below; both are exit 4, which is why the two messages each name
# the several causes rather than asserting one.) ──
: > "$STUB_LOG"
NOCROP="$WORK/no-crop-magick.sh"
write_stub "$NOCROP" ': # writes nothing, whatever flags it is handed'
out=$(FEANOR_MAGICK="$NOCROP" "$HOOK" "$FAKE_IMG" row 99999 2>/dev/null); st=$?
check "a crop that writes no file exits 4" "4" "$st"

# ── pixels that all fall under the minimum run length are not silently reported
# as "no deltas" — the hook fails loud so the caller cannot read it as a pass ──
cat > "$STUB_PIXELS" <<'PIX'
0,0: (255,255,255) #FFFFFF white
1,0: (0,0,0) #000000 black
PIX
out=$(FEANOR_MAGICK="$MAGICK" "$HOOK" "$FAKE_IMG" row 0 8 5 2>/dev/null); st=$?
check "no run meeting the minimum length exits 4" "4" "$st"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
