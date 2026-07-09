#!/bin/bash
# board.sh — the situation board's one entry. Subcommands:
#   serve                  boot or reuse the board server, lay the page, print the URL
#   add <KEY> [--active]   add or refresh a ticket channel (Jira or YouTrack)
#   remove <KEY>           drop a ticket channel, regenerate the manifest
#   refresh                re-fetch every ticket on the board (active preserved) + growth
#   list                   list the channels with status / AC
#
# Passthroughs to the channel writers: `growth` refreshes the metis growth tile,
# `sweep <name> <verdict> [detail]` records an amon-sul sweep verdict.
#
# Data lives under ~/.skadi/board/ (override with BOARD_DIR). The ticket writer,
# the growth writer, the henneth-link writer, the shared manifest, and the page
# are helpers beside this script in the hooks folder — this dispatcher only
# orchestrates them.

set -euo pipefail
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
THEME_SRC="$HOME/.claude/previews/henneth/skadi-theme.css"
DEFAULT_DONE='["4. DEV QA", "5. UAT@DEMO", "7. Done"]'

cmd="${1:-serve}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  add)
    exec "$DIR/board-ticket.sh" "$@"
    ;;

  growth)
    exec "$DIR/board-growth.sh" "$@"
    ;;

  sweep)
    exec "$DIR/board-sweep.sh" "$@"
    ;;

  remove)
    key="${1:-}"
    [[ -z "$key" ]] && { echo "usage: board.sh remove <KEY>" >&2; exit 1; }
    target="$BOARD_DIR/ticket-$key.json"
    [[ -f "$target" ]] || { echo "board: no channel ticket-$key" >&2; exit 1; }
    rm -f "$target"
    python3 "$DIR/board-manifest.py" "$BOARD_DIR"
    echo "removed $key"
    ;;

  refresh)
    shopt -s nullglob
    for chan in "$BOARD_DIR"/ticket-*.json; do
      id="$(jq -r '.id' "$chan")"
      tracker="$(jq -r '.source // "jira"' "$chan")"
      if [[ "$(jq -r '.active' "$chan")" == "true" ]]; then
        "$DIR/board-ticket.sh" "$id" --active --tracker "$tracker"
      else
        "$DIR/board-ticket.sh" "$id" --tracker "$tracker"
      fi
    done
    "$DIR/board-growth.sh" || echo "board: growth refresh failed (skipped)" >&2
    "$DIR/board-henneth.sh" || echo "board: henneth link refresh failed (skipped)" >&2
    ;;

  list)
    python3 - "$BOARD_DIR" <<'PY'
import json, os, sys
board = sys.argv[1]
manifest = os.path.join(board, "channels.json")
if not os.path.exists(manifest):
    print("board: no channels yet — run `board.sh add <KEY>` or `board.sh serve`")
    sys.exit(0)
for name in json.load(open(manifest, encoding="utf-8")).get("channels", []):
    try:
        d = json.load(open(os.path.join(board, name), encoding="utf-8"))
    except (ValueError, OSError):
        continue
    if d.get("channel") == "ticket":
        ac = d.get("ac") or {}
        pct = ("%d%%" % ac["pct"]) if ac.get("pct") is not None else "—"
        star = "*" if d.get("active") else " "
        print("%s %-10s %-16s AC %-5s %s" % (
            star, d.get("id", ""), d.get("status", ""), pct, (d.get("title") or "")[:48]))
    elif d.get("channel") == "growth":
        print("  %-10s WAU %s · MAU %s" % (d.get("app", "growth"), d.get("wau"), d.get("mau")))
    elif d.get("channel") == "sweep":
        print("  sweep %-10s %-8s %s" % (
            d.get("name", ""), d.get("verdict", ""), (d.get("detail") or "")[:40]))
PY
    ;;

  serve)
    mkdir -p "$BOARD_DIR"
    cp "$DIR/board-index.html" "$BOARD_DIR/index.html"
    [[ -f "$THEME_SRC" ]] && cp "$THEME_SRC" "$BOARD_DIR/skadi-theme.css"
    [[ -f "$BOARD_DIR/ac-done-statuses.json" ]] || printf '%s\n' "$DEFAULT_DONE" > "$BOARD_DIR/ac-done-statuses.json"
    "$DIR/board-henneth.sh" >/dev/null || echo "board: henneth link refresh failed (skipped)" >&2

    # Reuse a live server if the lockfile names one that still answers.
    if [[ -f "$BOARD_DIR/.board-port" ]]; then
      port="$(cat "$BOARD_DIR/.board-port")"
      if curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
        echo "http://localhost:$port/"
        exit 0
      fi
    fi

    # Boot a fresh server and wait for it to answer before handing over the URL,
    # so a boot that fails is reported, not papered over with a dead link.
    port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    echo "$port" > "$BOARD_DIR/.board-port"
    nohup python3 "$DIR/board-server.py" "$port" "$BOARD_DIR" >"$BOARD_DIR/.board-log" 2>&1 &
    disown
    if curl -sf -o /dev/null --retry 15 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/index.html"; then
      echo "http://localhost:$port/"
    else
      rm -f "$BOARD_DIR/.board-port"
      echo "board: server did not answer on $port — see $BOARD_DIR/.board-log" >&2
      exit 1
    fi
    ;;

  *)
    echo "usage: board.sh {serve | add <KEY> [--active] | remove <KEY> | refresh | list}" >&2
    exit 1
    ;;
esac
