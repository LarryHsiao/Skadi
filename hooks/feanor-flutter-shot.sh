#!/usr/bin/env bash
# feanor-flutter-shot.sh — screenshot a Flutter app already running on a booted
# emulator/simulator/device. It NEVER launches or kills a device — the user owns the
# emulator, boots it, and navigates to the target screen; this hook only captures it.
#
# Usage: feanor-flutter-shot.sh <out.png> [<deviceId>] [<Widget>]
#   out.png  : output image path (overwritten).
#   deviceId : optional `-d <id>` device selector, when more than one is attached.
#              Pass "" to name a widget without naming a device.
#   Widget   : optional widget class on screen (the page class, say) to shoot
#              through the VM service when `flutter screenshot` fails — it cannot
#              shoot a wireless iOS device ("Screenshot not supported ...
#              (wireless)"). The fallback reads the app's wsUri from the /narya
#              daemon's log (flutter-daemon.sh log) and hands it to
#              feanor-vm-shot.py, which asks the widget inspector for a PNG of
#              that widget. Debug/profile builds run through /narya only. The root
#              widget cannot be shot (offstage routes are not laid out), hence the
#              name. The inspector shot is the widget alone at pixel ratio 2, with
#              no OS chrome. $FEANOR_FLUTTER_DAEMON names the daemon script,
#              mainly for tests.
#
# The flutter command is found as `flutter` on PATH, else `fvm flutter`. The shot is
# the full device surface (OS status/nav bars included) — the comparing eye should
# weigh the app content region and ignore system chrome.
#
# Output: the out.png path on success. On failure, a message to stderr and a
# non-zero exit, so the caller's loop fails loud rather than aligning to nothing.
#   exit 2 — bad arguments
#   exit 3 — flutter not found
#   exit 4 — no screenshot produced (no booted device — boot one yourself), or
#            the inspector fallback ran and produced none
#   exit 5 — the inspector fallback has no VM service to reach: no /narya
#            daemon stands for this project/device, or its log bears no wsUri
set -u

out="${1:-}"
device="${2:-}"
widget="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
daemon="${FEANOR_FLUTTER_DAEMON:-$SCRIPT_DIR/flutter-daemon.sh}"
# Enough of the daemon log to reach back to app.debugPort, which flutter prints
# once at launch; a long session pushes it far up.
readonly daemon_log_lines=100000

if [ -z "$out" ]; then
  echo "usage: $0 <out.png> [<deviceId>] [<Widget>]" >&2
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

if [ -s "$out" ]; then
  echo "$out"
  exit 0
fi

detail="$(tail -n 3 "$err_log" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d')"
if [ -z "$widget" ]; then
  echo "feanor-flutter-shot: no screenshot produced — boot an emulator/simulator and navigate to the target screen first (this hook never launches one)" >&2
  [ -n "$detail" ] && echo "  flutter said: $detail" >&2
  echo "  a wireless device? run the app through /narya and name an on-screen widget as the third argument" >&2
  exit 4
fi

# The inspector fallback. The wsUri is learned from the daemon's own log, so
# only an app raised through /narya can be reached this way.
ws_uri="$("$daemon" log ${device:+-d "$device"} -n "$daemon_log_lines" 2>/dev/null \
  | grep -oE '"wsUri":"ws://[^"]+"' | tail -n 1 | sed 's/^"wsUri":"//; s/"$//')"
if [ -z "$ws_uri" ]; then
  echo "feanor-flutter-shot: flutter screenshot failed and no VM service wsUri was found — run the app through /narya (flutter-daemon.sh start) so its log carries one" >&2
  [ -n "$detail" ] && echo "  flutter said: $detail" >&2
  exit 5
fi

python3 -I "$SCRIPT_DIR/feanor-vm-shot.py" "$ws_uri" "$out" "$widget" >/dev/null 2>"$err_log" || true
if [ ! -s "$out" ]; then
  rm -f "$out"
  echo "feanor-flutter-shot: the inspector fallback produced no screenshot of $widget" >&2
  vm_detail="$(tail -n 3 "$err_log" 2>/dev/null | sed '/^[[:space:]]*$/d')"
  [ -n "$vm_detail" ] && echo "  feanor-vm-shot said: $vm_detail" >&2
  exit 4
fi

echo "$out"
