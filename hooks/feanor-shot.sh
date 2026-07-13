#!/usr/bin/env bash
# feanor-shot.sh — render a browser-loadable page to a PNG via headless Chrome/Edge.
#
# Usage: feanor-shot.sh <url> <out.png> [<WxH>]
#   url     : a browser-loadable locator — http(s):// (recommended; a served page,
#             React dev server, or Henneth URL) or file:// for a trivially-static
#             page. Passed to the browser verbatim; this hook does no path munging,
#             so dynamic pages and Windows paths must arrive as a served URL.
#   out.png : output image path (overwritten).
#   WxH     : viewport, e.g. 1440x900. Default 1280x800.
#
# A headless browser is found in this order: $FEANOR_BROWSER (an explicit binary),
# then chrome/chromium/edge on PATH, then the usual macOS and Windows install paths.
# Page settle time before the shot is $FEANOR_SETTLE_MS (default 2000ms), so JS and
# fonts resolve before the frame is captured.
#
# Output: the out.png path on success. On failure, a message to stderr and a
# non-zero exit, so the caller's loop fails loud rather than aligning to a blank.
#   exit 2 — bad arguments
#   exit 3 — no headless browser found
#   exit 4 — render produced no image
set -u

url="${1:-}"
out="${2:-}"
dims="${3:-1280x800}"

if [ -z "$url" ] || [ -z "$out" ]; then
  echo "usage: $0 <url> <out.png> [<WxH>]" >&2
  exit 2
fi

w="${dims%x*}"
h="${dims#*x}"
if ! [[ "$w" =~ ^[0-9]+$ ]] || ! [[ "$h" =~ ^[0-9]+$ ]]; then
  echo "feanor-shot: viewport must be WxH (digits), got '$dims'" >&2
  exit 2
fi

find_browser() {
  if [ -n "${FEANOR_BROWSER:-}" ] && [ -x "${FEANOR_BROWSER}" ]; then
    printf '%s' "$FEANOR_BROWSER"
    return 0
  fi
  local c
  for c in google-chrome google-chrome-stable chromium chromium-browser chrome msedge microsoft-edge; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  local p
  for p in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files/Microsoft/Edge/Application/msedge.exe" \
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"; do
    if [ -x "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

browser="$(find_browser)" || {
  echo "feanor-shot: no headless browser found — install Chrome/Edge or set FEANOR_BROWSER" >&2
  exit 3
}

settle="${FEANOR_SETTLE_MS:-2000}"

shoot() {
  "$browser" "$1" --disable-gpu --no-sandbox --hide-scrollbars \
    --force-device-scale-factor=1 --virtual-time-budget="$settle" \
    --window-size="$w,$h" --screenshot="$out" "$url" >/dev/null 2>&1 || true
}

# Headless exit codes are unreliable; judge by the produced file. Try the modern
# flag first, fall back to the legacy one for older browser builds.
rm -f "$out"
shoot "--headless=new"
[ -s "$out" ] || shoot "--headless"

if [ ! -s "$out" ]; then
  echo "feanor-shot: render produced no image for $url" >&2
  exit 4
fi

echo "$out"
