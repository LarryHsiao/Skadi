#!/usr/bin/env bash
# feanor-flutter-shot.sh — screenshot a Flutter app already running on a booted
# emulator/simulator/device. It NEVER launches or kills a device — the user owns the
# emulator, boots it, and navigates to the target screen; this hook only captures it.
#
# Usage: feanor-flutter-shot.sh <out.png> [<deviceId>]
#   out.png  : output image path (overwritten).
#   deviceId : optional `-d <id>` device selector, when more than one is attached.
#
# The flutter command is found as `flutter` on PATH, else `fvm flutter`. The shot is
# the full device surface (OS status/nav bars included) — the comparing eye should
# weigh the app content region and ignore system chrome.
#
# Output: the out.png path on success. On failure, a message to stderr and a
# non-zero exit, so the caller's loop fails loud rather than aligning to nothing.
#   exit 2 — bad arguments
#   exit 3 — flutter not found
#   exit 4 — no screenshot produced (no booted device — boot one yourself)
set -u

out="${1:-}"
device="${2:-}"

if [ -z "$out" ]; then
  echo "usage: $0 <out.png> [<deviceId>]" >&2
  exit 2
fi

find_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    echo "flutter"
    return 0
  fi
  if command -v fvm >/dev/null 2>&1; then
    echo "fvm flutter"
    return 0
  fi
  return 1
}

fl="$(find_flutter)" || {
  echo "feanor-flutter-shot: flutter not found — install Flutter or fvm" >&2
  exit 3
}

rm -f "$out"
err_log="$(mktemp -t feanor-flutter.XXXXXX)"
trap 'rm -f "$err_log"' EXIT

# $fl is intentionally unquoted to split "fvm flutter" into command + subcommand.
# flutter's own stderr is kept (not discarded) so a failure can name its cause.
if [ -n "$device" ]; then
  $fl screenshot --out="$out" -d "$device" >/dev/null 2>"$err_log" || true
else
  $fl screenshot --out="$out" >/dev/null 2>"$err_log" || true
fi

if [ ! -s "$out" ]; then
  echo "feanor-flutter-shot: no screenshot produced — boot an emulator/simulator and navigate to the target screen first (this hook never launches one)" >&2
  detail="$(tail -n 3 "$err_log" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d')"
  [ -n "$detail" ] && echo "  flutter said: $detail" >&2
  exit 4
fi

echo "$out"
