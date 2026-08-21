#!/bin/bash
# board.sh — the situation board's one entry. Subcommands:
#   serve                          boot or reuse the board server, lay the page, print the URL
#   add <KEY> [--active]           add or refresh a ticket channel (Jira or YouTrack)
#   remove <KEY>                   drop a ticket channel, regenerate the manifest
#   refresh [--stability-scrape]   re-fetch every ticket (active preserved) + growth; the
#                                   flag additionally sweeps every bound app's live crash-free
#                                   number and, for any BigQuery can't answer, prints what the
#                                   model needs to run /beleg's console-scrape flow itself —
#                                   a hook cannot drive Chrome, so this never scrapes on its own
#   stability-write <label> --from-json <file>
#                                   normalize a model-scraped console reading for <label> into
#                                   stability-<slug>.json, the Stability tile's fallback channel
#   list                           list the channels with status / AC
#
# Passthroughs to the channel writers: `growth` refreshes the metis growth tile,
# `sweep <name> <verdict> [detail] [scope]` records an amon-sul sweep verdict —
# the optional scope pins one skill's ride to a project so two scopes coexist,
# `pulse` recomputes the adherence pulse channel + dashboard, `attention
# <mrs|prs|jira> [--clear]` refreshes one "what awaits me" surface (or `mail
# --from-json <file> | --clear`, the model-fed surface refresh can't fetch).
#
# Data lives under ~/.skadi/board/ (override with BOARD_DIR). The ticket writer,
# the growth writer, the attention writer, the henneth-link writer, the shared
# manifest, and the page are helpers beside this script in the hooks folder —
# this dispatcher only orchestrates them.

set -euo pipefail
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
BOARD_PORT="${BOARD_PORT:-10000}"
HENNETH_DIR="$HOME/.skadi/henneth"
THEME_SRC="$HENNETH_DIR/skadi-theme.css"
SKILLS_CHEATSHEET_DEST="$HENNETH_DIR/skills-cheatsheet.html"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
DEFAULT_DONE='["4. DEV QA", "5. UAT@DEMO", "7. Done"]'

# Where the skadi repo stands. board-server.py serves /handbook/ and /previews/
# from BOARD_SKADI_ROOT, and both live in the repo — never in a config root.
# Run from the repo this script's own parent is the answer; run from the copy
# install.sh lays under ~/.claude (which is what /board and /minuial boot), it is
# not, so the installer records the root and this reads it. An explicit override
# wins over both, and an unresolvable root is left empty for the server to fall
# back on rather than guessed at.
# Test seam: SKADI_ROOT_RECORD overrides where the recorded root is read from.
SKADI_ROOT_RECORD="${SKADI_ROOT_RECORD:-$HOME/.skadi/install/skadi-root}"
if [[ -z "${BOARD_SKADI_ROOT:-}" ]]; then
  if [[ -d "$DIR/../handbook" ]]; then
    BOARD_SKADI_ROOT="$(cd "$DIR/.." && pwd)"
  elif [[ -r "$SKADI_ROOT_RECORD" ]]; then
    recorded="$(<"$SKADI_ROOT_RECORD")"
    # A record naming a repo that has since moved or gone would export a root
    # the server cannot serve from — no better than the fallback it replaces,
    # and harder to diagnose. Leave it empty instead.
    [[ -d "$recorded/handbook" ]] && BOARD_SKADI_ROOT="$recorded"
  fi
fi
[[ -n "${BOARD_SKADI_ROOT:-}" ]] && export BOARD_SKADI_ROOT

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

  attention)
    exec "$DIR/board-attention.sh" "$@"
    ;;

  pulse)
    exec python3 "$DIR/pulse-scan.py" "$@"
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
    stability_scrape=""
    for a in "$@"; do
      [[ "$a" == "--stability-scrape" ]] && stability_scrape=1
    done

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
    for surface in mrs prs jira; do
      "$DIR/board-attention.sh" "$surface" \
        || echo "board: attention $surface refresh failed (skipped)" >&2
    done
    "$DIR/board-growth.sh" || echo "board: growth refresh failed (skipped)" >&2
    "$DIR/board-henneth.sh" || echo "board: henneth link refresh failed (skipped)" >&2
    "$DIR/board-galadriel.sh" || echo "board: galadriel link refresh failed (skipped)" >&2
    python3 "$DIR/skills-cheatsheet-render.py" "$CLAUDE_SKILLS_DIR" "$SKILLS_CHEATSHEET_DEST" \
      || echo "board: skills cheatsheet render failed (skipped)" >&2

    # The scrape itself never runs here — a hook cannot drive Chrome. This
    # only names which apps need it, for the model to act on next. The report
    # text lives in board-stability.py's own format_sweep_report() — pure and
    # unit-tested there, so this case stays a one-line passthrough.
    if [[ -n "$stability_scrape" ]]; then
      python3 "$DIR/board-stability.py" sweep-report \
        || echo "board: stability sweep failed (skipped)" >&2
    fi
    ;;

  stability-write)
    label="${1:-}"
    [[ $# -gt 0 ]] && shift
    json_arg=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from-json)
          if [[ $# -lt 2 ]]; then
            echo "usage: board.sh stability-write <label> --from-json <file>" >&2
            exit 1
          fi
          json_arg="$2"
          shift 2
          ;;
        *) echo "board: unknown stability-write arg: $1" >&2; exit 1 ;;
      esac
    done
    if [[ -z "$label" || -z "$json_arg" ]]; then
      echo "usage: board.sh stability-write <label> --from-json <file>" >&2
      exit 1
    fi
    [[ -f "$json_arg" ]] || { echo "board: no such file $json_arg" >&2; exit 1; }

    mkdir -p "$BOARD_DIR"
    channel_out="$(python3 "$DIR/board-stability.py" write "$label" --from-json "$json_arg")" || exit 1
    slug="$(printf '%s' "$channel_out" | jq -r '.slug')"
    python3 - "$BOARD_DIR" "$channel_out" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" <<'PY'
import json, os, sys
board, channel_json, now, slug = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.loads(channel_json)
data["updated"] = now
with open(os.path.join(board, "stability-%s.json" % slug), "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
PY
    python3 "$DIR/board-manifest.py" "$BOARD_DIR"
    echo "wrote $BOARD_DIR/stability-$slug.json"
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
    elif d.get("channel") == "attention":
        count = "—" if d.get("count") is None else d.get("count")
        print("  attn  %-10s %-8s %s" % (
            d.get("surface", ""), count, (d.get("detail") or "")[:40]))
PY
    ;;

  serve)
    mkdir -p "$BOARD_DIR"
    cp "$DIR/board-index.html" "$BOARD_DIR/index.html"
    [[ -f "$THEME_SRC" ]] && cp "$THEME_SRC" "$BOARD_DIR/skadi-theme.css"
    [[ -f "$BOARD_DIR/ac-done-statuses.json" ]] || printf '%s\n' "$DEFAULT_DONE" > "$BOARD_DIR/ac-done-statuses.json"
    "$DIR/board-henneth.sh" >/dev/null || echo "board: henneth link refresh failed (skipped)" >&2
    "$DIR/board-galadriel.sh" >/dev/null || echo "board: galadriel link refresh failed (skipped)" >&2
    python3 "$DIR/skills-cheatsheet-render.py" "$CLAUDE_SKILLS_DIR" "$SKILLS_CHEATSHEET_DEST" \
      >/dev/null || echo "board: skills cheatsheet render failed (skipped)" >&2

    # The port is fixed (BOARD_PORT, default 10000) so the URL never drifts
    # across restarts. Reuse a live server already bound there.
    port="$BOARD_PORT"
    if curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
      echo "http://localhost:$port/"
      exit 0
    fi

    # Boot a fresh server and wait for it to answer before handing over the URL.
    # If the port is held by something other than a dead board server, the bind
    # fails, the process exits at once, and the retry loop below reports it
    # loudly rather than silently falling back to a different port.
    nohup python3 "$DIR/board-server.py" "$port" "$BOARD_DIR" >"$BOARD_DIR/.board-log" 2>&1 &
    disown
    if curl -sf -o /dev/null --retry 15 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/index.html"; then
      echo "http://localhost:$port/"
    else
      echo "board: server did not answer on $port — see $BOARD_DIR/.board-log" >&2
      exit 1
    fi
    ;;

  *)
    echo "usage: board.sh {serve | add <KEY> [--active] | remove <KEY> | refresh [--stability-scrape] | attention <mrs|prs|jira> [--clear] | attention mail [--clear | --from-json <file>] | stability-write <label> --from-json <file> | list}" >&2
    exit 1
    ;;
esac
