#!/usr/bin/env bash
# feanor-measure.sh — report the colour runs along one row or column of an image.
#
# Usage: feanor-measure.sh <image> row|col <index> [<tol>] [<min-run>]
#   image   : path to a PNG (or any ImageMagick-readable image), typically a
#             feanor-pass-<n>.png or feanor-spec.png shot.
#   row|col : scan a horizontal row (measuring along x) or a vertical column
#             (measuring along y).
#   index   : which row (y) or column (x) to scan, in image pixels.
#   tol     : per-channel tolerance holding a run together, default 8. A pixel
#             joins the current run while every channel stays within tol of the
#             colour the run STARTED on — so a gradient breaks into runs rather
#             than drifting silently into one.
#   min-run : runs shorter than this are omitted, default 2, which drops the
#             one- and two-pixel anti-aliasing bands that sit between real
#             regions. Boundaries then read off the surviving runs' own starts.
#
# Where a scale factor and a boundary position are what a check needs, this is
# the whole measurement: an element's extent is one run's length, and an inset
# is the run standing between two others. Reading those off a cropped PNG by eye
# is what makes measuring expensive enough to skip — which is the failure this
# hook exists to price out.
#
# ImageMagick (`magick`, or the legacy `convert`) is required. $FEANOR_MAGICK
# names an explicit binary, bypassing the PATH search — mainly for tests.
#
# Output: one line per run, `<start> <end> <length> #RRGGBB`, in scan order.
#   exit 2 — bad arguments
#   exit 3 — ImageMagick not found
#   exit 4 — nothing was measured: the crop yielded no image, the index fell
#            outside the image, the source is greyscale (its pixel dump carries
#            no rgb triples), or no run reached min-run. Never a silent empty
#            result — an unmeasured line must not read as an unremarkable one.
set -u

img="${1:-}"
axis="${2:-}"
index="${3:-}"
tol="${4:-8}"
min_run="${5:-2}"

if [ -z "$img" ] || [ -z "$axis" ] || [ -z "$index" ]; then
  echo "usage: $0 <image> row|col <index> [<tol>] [<min-run>]" >&2
  exit 2
fi

if [ "$axis" != "row" ] && [ "$axis" != "col" ]; then
  echo "feanor-measure: axis must be 'row' or 'col', got '$axis'" >&2
  exit 2
fi

for n in "$index" "$tol" "$min_run"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "feanor-measure: index, tol and min-run must be non-negative integers, got '$n'" >&2
    exit 2
  fi
done

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
  echo "feanor-measure: ImageMagick not found — install it (magick or convert on PATH)" >&2
  exit 3
}

# A row is the full width one pixel tall; a column the full height one pixel wide.
# The offset geometry leaves the other extent at 0 so ImageMagick runs to the edge.
if [ "$axis" = "row" ]; then
  crop_geom="+0+${index}"
  crop_size="x1"
else
  crop_geom="+${index}+0"
  crop_size="1x"
fi

tmp="$(mktemp -t feanor-measure.XXXXXX)"
line="${tmp}.png"
trap 'rm -f "$tmp" "$line"' EXIT

# The leading +repage matters: an omitted crop dimension resolves against the
# image's PAGE geometry, not its pixel width, so an image carrying a smaller page
# would scan a truncated line and report a confidently wrong measurement rather
# than failing. Clearing the page first makes the crop resolve against real
# pixels; the trailing +repage resets the offset the crop itself leaves behind.
"$im" "$img" +repage -crop "${crop_size}${crop_geom}" +repage "$line" >/dev/null 2>&1

if [ ! -s "$line" ]; then
  echo "feanor-measure: scan produced no pixels — check the image path and that $axis $index is in bounds" >&2
  exit 4
fi

# txt: enumerates as "x,y: (r,g,b,...)". A row varies in x, a column in y, so
# keep whichever coordinate moves and let awk group the runs.
if [ "$axis" = "row" ]; then
  coord='\1'
else
  coord='\2'
fi

runs="$("$im" "$line" -depth 8 txt: 2>/dev/null \
  | sed -n "s/^\([0-9][0-9]*\),\([0-9][0-9]*\): (\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\),[[:space:]]*\([0-9][0-9]*\).*/${coord} \3 \4 \5/p" \
  | awk -v tol="$tol" -v minrun="$min_run" '
      function near(a, b,   d) { d = a - b; if (d < 0) d = -d; return d <= tol }
      function flush(  len) {
        len = prev_pos - start_pos + 1
        if (len >= minrun)
          printf "%d %d %d #%02X%02X%02X\n", start_pos, prev_pos, len, sr, sg, sb
      }
      NR == 1 { start_pos = $1; sr = $2; sg = $3; sb = $4 }
      NR > 1 && !(near($2, sr) && near($3, sg) && near($4, sb)) {
        flush()
        start_pos = $1; sr = $2; sg = $3; sb = $4
      }
      { prev_pos = $1 }
      END { if (NR > 0) flush() }
    ')"

if [ -z "$runs" ]; then
  echo "feanor-measure: measured nothing along $axis $index — the index may fall outside the image, the source may be greyscale, or no run reached the minimum length of $min_run" >&2
  exit 4
fi

printf '%s\n' "$runs"
