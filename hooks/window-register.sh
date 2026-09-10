#!/usr/bin/env bash
# Registers or unregisters one entry in the generic standing-windows registry
# statusline.sh reads (see that file's "Standing windows" section). Any script
# that starts a local server a person might want to click into — a Flutter
# DevTools session, a blog preview, anything else — drops one two-line file
# here: url on line 1, label on line 2. The statusline still probes the port
# itself before drawing a link, so a stale file left by a crashed process
# draws nothing and is pruned the next time the statusline finds it silent;
# calling `unregister` on a clean shutdown is a courtesy, not a requirement.
set -euo pipefail

WINDOWS_DIR="${SKADI_WINDOWS_DIR:-$HOME/.skadi/windows}"

usage() {
    echo "Usage: window-register.sh register <name> <url> <label>" >&2
    echo "       window-register.sh unregister <name>" >&2
    exit 1
}

[ $# -ge 1 ] || usage
verb="$1"
shift

case "$verb" in
    register)
        [ $# -eq 3 ] || usage
        name="$1"
        url="$2"
        label="$3"
        mkdir -p "$WINDOWS_DIR"
        printf '%s\n%s\n' "$url" "$label" > "$WINDOWS_DIR/$name"
        ;;
    unregister)
        [ $# -eq 1 ] || usage
        name="$1"
        rm -f "$WINDOWS_DIR/$name"
        ;;
    *)
        usage
        ;;
esac
