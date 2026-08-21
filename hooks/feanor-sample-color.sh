#!/usr/bin/env bash
# feanor-sample-color.sh — sample the most-saturated pixel in an image region.
#
# Usage: feanor-sample-color.sh <image> <x> <y> <w> <h>
#   image : path to a PNG (or any ImageMagick-readable image), typically a
#           feanor-pass-<n>.png or feanor-spec.png shot.
#   x,y   : top-left corner of the region to sample, in image pixels.
#   w,h   : region size, in image pixels.
#
# Scans every pixel in the region and returns the one with the highest
# chroma (max(R,G,B) - min(R,G,B)) — the pixel that carries the region's
# real color, ignoring a white/gray/black background or an anti-aliased
# edge. This is the check a holistic side-by-side read cannot make good on:
# same-hue-family token variants (e.g. a `warning.main` icon vs. a
# `warning.dark` regression) read alike to the eye but diverge in a direct
# pixel sample.
#
# ImageMagick (`magick`, or the legacy `convert`) is required. $FEANOR_MAGICK
# names an explicit binary, bypassing the PATH search — mainly for tests.
#
# Output: "<#RRGGBB> <R,G,B>" on success — one line, stdout.
#   exit 2 — bad arguments
#   exit 3 — ImageMagick not found
#   exit 4 — region produced no sample (out of the image's bounds, or unreadable image)
set -u

img="${1:-}"
x="${2:-}"
y="${3:-}"
w="${4:-}"
h="${5:-}"

if [ -z "$img" ] || [ -z "$x" ] || [ -z "$y" ] || [ -z "$w" ] || [ -z "$h" ]; then
  echo "usage: $0 <image> <x> <y> <w> <h>" >&2
  exit 2
fi

for n in "$x" "$y" "$w" "$h"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "feanor-sample-color: x, y, w, h must be non-negative integers, got '$n'" >&2
    exit 2
  fi
done
if [ "$w" -eq 0 ] || [ "$h" -eq 0 ]; then
  echo "feanor-sample-color: w and h must be greater than 0" >&2
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
  echo "feanor-sample-color: ImageMagick not found — install it (magick or convert on PATH)" >&2
  exit 3
}

tmp="$(mktemp -t feanor-sample.XXXXXX)"
crop="${tmp}.png"
trap 'rm -f "$tmp" "$crop"' EXIT

"$im" "$img" -crop "${w}x${h}+${x}+${y}" +repage "$crop" >/dev/null 2>&1

if [ ! -s "$crop" ]; then
  echo "feanor-sample-color: crop produced no image — check the image path and region bounds" >&2
  exit 4
fi

best="$("$im" "$crop" -depth 8 txt: 2>/dev/null \
  | sed -n 's/^[0-9][0-9]*,[0-9][0-9]*: (\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\).*/\1 \2 \3/p' \
  | awk '
      { r=$1; g=$2; b=$3
        max=r; if(g>max)max=g; if(b>max)max=b
        min=r; if(g<min)min=g; if(b<min)min=b
        sat=max-min
        if (NR==1 || sat>bestsat) { bestsat=sat; br=r; bg=g; bb=b }
      }
      END { if (NR>0) printf "%d %d %d\n", br, bg, bb }
    ')"

if [ -z "$best" ]; then
  echo "feanor-sample-color: no pixels sampled from the cropped region" >&2
  exit 4
fi

read -r br bg bb <<< "$best"
printf '#%02X%02X%02X %d,%d,%d\n' "$br" "$bg" "$bb" "$br" "$bg" "$bb"
