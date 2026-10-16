#!/usr/bin/env bash
# feanor-ink-centre.sh — report the vertical ink extent and centre of one x-span.
#
# Usage: feanor-ink-centre.sh <image> <x0> <x1> [<y0> <y1>]
#   image : path to a PNG (or any ImageMagick-readable image), typically a
#           feanor-pass-<n>.png or manwe-shot.png shot.
#   x0 x1 : the span's columns, x0 inclusive and x1 exclusive, in image pixels.
#   y0 y1 : optional row range to scan, y0 inclusive and y1 exclusive; the
#           whole height when omitted. Give both or neither. Every pixel in the
#           span is dumped as text, so on a full-height retina shot a range
#           around the row being weighed keeps the call quick.
#
# A pixel is ink when its R+G+B falls below $FEANOR_INK_SUM (default 500) after
# transparency is flattened onto white. 500 sits above Material's 54%-black
# action.active icon on white (117 per channel, sum 351), so a muted icon counts,
# and below light-grey dividers and fills (200 per channel and lighter).
#
# Why it exists: when an icon and a text share a row, their widget boxes can be
# perfectly centred while the glyphs are not — a tall line height puts the text's
# ink below its box centre, and a geometry check (tester.getCenter, an inspector
# rect) passes on the broken render. Run this once over the icon's span and once
# over a descender-free word of the text, and compare the two centres.
#
# ImageMagick (`magick`, or the legacy `convert`) is required. $FEANOR_MAGICK
# names an explicit binary, bypassing the PATH search — mainly for tests.
#
# Output: one line, `x <x0>-<x1>: rows <first>-<last>, centre <c>`, rows in image
# coordinates.
#   exit 2 — bad arguments
#   exit 3 — ImageMagick not found
#   exit 4 — nothing was measured: the span fell outside the image, or held no
#            ink. Never a silent empty result — an unmeasured span must not
#            read as a centred one.
set -u

readonly default_ink_sum=500

img="${1:-}"
x0="${2:-}"
x1="${3:-}"
y0="${4:-}"
y1="${5:-}"
ink_sum="${FEANOR_INK_SUM:-$default_ink_sum}"

usage() {
  echo "usage: $0 <image> <x0> <x1> [<y0> <y1>]" >&2
  exit 2
}

[ -n "$img" ] && [ -n "$x0" ] && [ -n "$x1" ] || usage
if { [ -n "$y0" ] && [ -z "$y1" ]; } || { [ -z "$y0" ] && [ -n "$y1" ]; }; then
  usage
fi

for n in "$x0" "$x1" ${y0:+"$y0"} ${y1:+"$y1"} "$ink_sum"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "feanor-ink-centre: coordinates and FEANOR_INK_SUM must be non-negative integers, got '$n'" >&2
    exit 2
  fi
done

if [ "$x1" -le "$x0" ]; then
  echo "feanor-ink-centre: x1 ($x1) must be past x0 ($x0)" >&2
  exit 2
fi
if [ -n "$y0" ] && [ "$y1" -le "$y0" ]; then
  echo "feanor-ink-centre: y1 ($y1) must be past y0 ($y0)" >&2
  exit 2
fi

find_magick() {
  if [ -n "${FEANOR_MAGICK:-}" ] && [ -x "${FEANOR_MAGICK}" ]; then
    printf '%s' "$FEANOR_MAGICK"
    return 0
  fi
  if command -v magick >/dev/null 2>&1; then
    command -v magick
    return 0
  fi
  if command -v convert >/dev/null 2>&1; then
    command -v convert
    return 0
  fi
  return 1
}

im="$(find_magick)" || {
  echo "feanor-ink-centre: ImageMagick not found — install it (magick or convert on PATH)" >&2
  exit 3
}

# An omitted height runs the crop to the bottom edge; the leading +repage makes
# it resolve against real pixels rather than a smaller PAGE geometry (the same
# trap feanor-measure.sh names).
top="${y0:-0}"
height=""
[ -n "$y1" ] && height=$((y1 - y0))
crop="$((x1 - x0))x${height}+${x0}+${top}"

tmp="$(mktemp -t feanor-ink.XXXXXX)"
region="${tmp}.png"
trap 'rm -f "$tmp" "$region"' EXIT

# PNG24: keeps the region truecolour. A crop of black text on white is the
# common case here, and ImageMagick would otherwise save it as greyscale, whose
# txt: dump carries no rgb triples for the parser below.
"$im" "$img" +repage -crop "$crop" +repage \
  -background white -alpha remove -alpha off "PNG24:$region" >/dev/null 2>&1

if [ ! -s "$region" ]; then
  echo "feanor-ink-centre: crop $crop produced no pixels — check the image path and that the span is in bounds" >&2
  exit 4
fi

# txt: enumerates as "x,y: (r,g,b)"; keep the dark pixels' y, shifted back into
# image coordinates, and report the first and last row bearing any.
result="$("$im" "$region" -depth 8 txt: 2>/dev/null \
  | sed -n 's/^[0-9][0-9]*,\([0-9][0-9]*\): (\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\).*/\1 \2 \3 \4/p' \
  | awk -v limit="$ink_sum" -v top="$top" -v x0="$x0" -v x1="$x1" '
      $2 + $3 + $4 < limit {
        y = $1 + top
        if (!found || y < first) first = y
        if (!found || y > last) last = y
        found = 1
      }
      END {
        if (found)
          printf "x %d-%d: rows %d-%d, centre %.1f\n", x0, x1, first, last, (first + last) / 2
      }
    ')"

if [ -z "$result" ]; then
  echo "feanor-ink-centre: no ink in x $x0-$x1 (no pixel's R+G+B under $ink_sum) — the span may hold only background, or the shot may be inverted (dark mode)" >&2
  exit 4
fi

printf '%s\n' "$result"
