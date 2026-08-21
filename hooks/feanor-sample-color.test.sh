#!/bin/bash
# Offline tests for the region color-sampling hook. Run from anywhere: bash feanor-sample-color.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/feanor-sample-color.sh"
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

# ── missing or malformed arguments fail loud rather than sampling garbage ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no arguments at all exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 2>/dev/null); st=$?
check "missing x/y/w/h exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 0 0 "not-a-number" 10 2>/dev/null); st=$?
check "non-numeric w exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 0 0 0 10 2>/dev/null); st=$?
check "zero-width region exits 2" "2" "$st"

out=$("$HOOK" "$FAKE_IMG" 0 0 10 0 2>/dev/null); st=$?
check "zero-height region exits 2" "2" "$st"

# ── ImageMagick's "not found" branch depends on what happens to be installed on
# the machine running the suite (the same reasoning feanor-shot.test.sh gives for
# skipping its browser-not-found branch) — not asserted here for the same reason. ──

# ── a stub standing in for `magick`, selected via FEANOR_MAGICK so the real
# binary (whose presence is machine-dependent) is never consulted ──
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

# ── the happy path: the crop call succeeds, the txt: dump carries one clearly
# saturated pixel among near-gray neighbours, and that pixel's hex/rgb wins ──
HAPPY="$WORK/happy-magick.sh"
write_stub "$HAPPY" '
has_crop=0
for a in "$@"; do
  last="$a"
  case "$a" in
    -crop) has_crop=1 ;;
  esac
done
if [ "$has_crop" = "1" ]; then
  printf "FAKE-CROP" > "$last"
  exit 0
fi
case "$*" in
  *"txt:"*)
    printf "%s\n" \
      "# ImageMagick pixel enumeration: 4,2,255,srgb" \
      "0,0: (255,255,255) #FFFFFFFF white" \
      "1,0: (237,108,2) #ED6C02FF srgb(237,108,2)" \
      "2,0: (250,250,250) #FAFAFAFF srgb(250,250,250)" \
      "3,0: (255,255,255) #FFFFFFFF white" \
      "0,1: (255,255,255) #FFFFFFFF white" \
      "1,1: (240,240,240) #F0F0F0FF srgb(240,240,240)" \
      "2,1: (255,255,255) #FFFFFFFF white" \
      "3,1: (255,255,255) #FFFFFFFF white"
    ;;
esac
'
out=$(FEANOR_MAGICK="$HAPPY" "$HOOK" "$FAKE_IMG" 10 20 4 2); st=$?
check "a working ImageMagick exits 0" "0" "$st"
check "the most-saturated pixel wins over near-gray neighbours" "#ED6C02 237,108,2" "$out"
check "the region reaches the crop call as -crop 4x2+10+20" "1" "$(grep -c -- '-crop 4x2+10+20' "$STUB_LOG")"

# ── a crop that produces no image (region outside the source image's bounds,
# or an unreadable image) fails loud rather than sampling nothing ──
: > "$STUB_LOG"
NOCROP="$WORK/no-crop-magick.sh"
write_stub "$NOCROP" ': # writes nothing, whatever flags it is handed'
out=$(FEANOR_MAGICK="$NOCROP" "$HOOK" "$FAKE_IMG" 9999 9999 4 2 2>/dev/null); st=$?
check "a crop producing no image exits 4" "4" "$st"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
