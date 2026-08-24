#!/usr/bin/env bash
# feanor-crop.sh — cut one region out of an image into its own PNG.
#
# Usage: feanor-crop.sh <image> <x> <y> <w> <h> <out.png>
#   image   : path to a PNG (or any ImageMagick-readable image), typically a
#             feanor-pass-<n>.png or feanor-spec.png shot.
#   x,y     : top-left corner of the region to cut, in image pixels.
#   w,h     : region size, in image pixels.
#   out.png : where the cut region is written; the Henneth folder by convention,
#             so the crop stands in the window beside the shot it came from.
#
# The eye reading a whole screen renders a small gap as a handful of pixels and
# cannot judge it; the same gap read as its own image becomes a proportion that
# can be stated as a number. This is the instrument the compare step's
# fraction-of-a-stable-parent rule prescribes but never named — measure the
# region against a stable parent in both spec and build, then compare the two
# fractions.
#
# Deliberately crops only, never upscales: a zoom carries no information the
# same pixels did not already, and the measurement is a proportion against the
# crop's own known dimensions.
#
# ImageMagick (`magick`, or the legacy `convert`) is required. $FEANOR_MAGICK
# names an explicit binary, bypassing the PATH search — mainly for tests.
#
# Output: the out path on success — one line, stdout.
#   exit 2 — bad arguments
#   exit 3 — ImageMagick not found
#   exit 4 — crop produced no image (out of the image's bounds, or unreadable image)
set -u

img="${1:-}"
x="${2:-}"
y="${3:-}"
w="${4:-}"
h="${5:-}"
out="${6:-}"

if [ -z "$img" ] || [ -z "$x" ] || [ -z "$y" ] || [ -z "$w" ] || [ -z "$h" ] || [ -z "$out" ]; then
  echo "usage: $0 <image> <x> <y> <w> <h> <out.png>" >&2
  exit 2
fi

for n in "$x" "$y" "$w" "$h"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "feanor-crop: x, y, w, h must be non-negative integers, got '$n'" >&2
    exit 2
  fi
done
if [ "$w" -eq 0 ] || [ "$h" -eq 0 ]; then
  echo "feanor-crop: w and h must be greater than 0" >&2
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
  echo "feanor-crop: ImageMagick not found — install it (magick or convert on PATH)" >&2
  exit 3
}

mkdir -p "$(dirname "$out")" 2>/dev/null

"$im" "$img" -crop "${w}x${h}+${x}+${y}" +repage "$out" >/dev/null 2>&1

if [ ! -s "$out" ]; then
  rm -f "$out"
  echo "feanor-crop: crop produced no image — check the image path and region bounds" >&2
  exit 4
fi

printf '%s\n' "$out"
