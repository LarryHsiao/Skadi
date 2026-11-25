#!/bin/bash
# board-growth.sh
#
# Writes the growth channel the situation board reads. For each app listed in
# ~/.skadi/growth-apps.tsv (default: metis alone), runs the /growth hook
# (appgrowth.py) — which renders that app's full dashboard into the Henneth
# folder and prints its headline — parses WAU/MAU from the headline, copies the
# page in as the Enter door, and writes ~/.skadi/board/growth.json: the summed
# totals (WAU/MAU and their priors), an `apps` list with each app's own numbers,
# and `partial` when an app has none. Then regenerates the manifest via the
# shared board-manifest.py.
#
# The apps file is machine state, not repo content. One app per line, tab-
# separated: app, project, dataset, [account]. A blank project/dataset takes
# appgrowth's own default; a dataset of `-` means the app has no GA4 export yet.
# `#` starts a comment line.
#
# Test seams: BOARD_GROWTH_OUT injects appgrowth's stdout for every app, and
# BOARD_GROWTH_OUT_<APP> for one (skipping BigQuery), so board-growth.test.sh
# exercises the real parse offline. BOARD_DIR overrides the folder;
# GROWTH_APPS_FILE overrides the apps file.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPGROWTH="$HOME/.claude/hooks/appgrowth.py"
HENNETH="$HOME/.skadi/henneth"
APPS_FILE="${GROWTH_APPS_FILE:-$HOME/.skadi/growth-apps.tsv}"

mkdir -p "$BOARD_DIR"

python3 - "$BOARD_DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APPGROWTH" "$HENNETH" "$APPS_FILE" <<'PY'
import json, os, re, shutil, subprocess, sys

board, now, appgrowth, henneth, apps_file = sys.argv[1:6]
HEADLINE = re.compile(r'WAU\s+(\d+)\s+\(prev\s+(\d+)\).*MAU\s+(\d+)\s+\(prev\s+(\d+)\)')
NAME = re.compile(r'^[a-z0-9_-]+$')
NO_EXPORT = "-"


def read_apps():
    """(app, project, dataset, account) rows; metis alone when no file stands."""
    if not os.path.isfile(apps_file):
        return [("metis", "", "", "")]
    rows = []
    with open(apps_file, encoding="utf-8") as fh:
        for raw in fh:
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            cols = (raw.rstrip("\r\n").split("\t") + ["", "", "", ""])[:4]
            rows.append(tuple(c.strip() for c in cols))
    return rows or [("metis", "", "", "")]


def run_headline(app, project, dataset, account):
    """appgrowth's stdout for one app — injected under test, else a real run."""
    injected = (os.environ.get("BOARD_GROWTH_OUT_" + re.sub(r'\W', '_', app).upper())
                or os.environ.get("BOARD_GROWTH_OUT"))
    if injected:
        return injected, False
    env = dict(os.environ, GROWTH_APP=app)
    for key, value in (("GROWTH_PROJECT", project), ("GROWTH_DATASET", dataset),
                       ("GROWTH_ACCOUNT", account)):
        if value:
            env[key] = value
    if not os.path.isfile(appgrowth):
        raise RuntimeError("cannot run appgrowth: no such file")
    try:
        # Through the interpreter: Windows cannot spawn a .py directly.
        done = subprocess.run([sys.executable, appgrowth], capture_output=True, env=env)
    except OSError as failure:
        raise RuntimeError(f"cannot run appgrowth: {failure.strerror}")
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).decode("utf-8", "replace").strip()
        raise RuntimeError(detail.splitlines()[-1] if detail else f"exit {done.returncode}")
    return done.stdout.decode("utf-8", "replace"), True


def entry(app, project, dataset, account):
    """One app's channel row: numbers when it has them, else null plus a note."""
    row = {"app": app, "wau": None, "wau_prev": None, "mau": None, "mau_prev": None,
           "url": None, "note": None}
    if not NAME.match(app):
        row["note"] = "bad app name"
        return row
    if dataset == NO_EXPORT:
        row["note"] = "no export"
        return row
    try:
        out, real = run_headline(app, project, dataset, account)
    except RuntimeError as failure:
        row["note"] = f"query failed: {failure}"
        return row
    match = next((m for m in map(HEADLINE.search, out.splitlines()) if m), None)
    if not match:
        row["note"] = "unparseable headline"
        return row
    row["wau"], row["wau_prev"], row["mau"], row["mau_prev"] = map(int, match.groups())
    page = os.path.join(henneth, f"{app}-growth.html")
    door = os.path.join(board, f"growth-{app}.html")
    if real and os.path.isfile(page):
        shutil.copyfile(page, door)
    # The Enter door is set only when its page actually exists, lest the tile link 404.
    row["url"] = f"growth-{app}.html" if os.path.isfile(door) else None
    return row


apps = [entry(*cols) for cols in read_apps()]
have = [a for a in apps if a["wau"] is not None]
for a in apps:
    if a["wau"] is None and a["note"] != "no export":
        print(f"board-growth: {a['app']}: {a['note']}", file=sys.stderr)
if not have:
    sys.exit("board-growth: no app produced numbers: "
             + "; ".join(f"{a['app']} ({a['note']})" for a in apps))

total = lambda key: sum(a[key] for a in have)
out = {
    "channel": "growth",
    "app": " + ".join(a["app"] for a in apps),
    "wau": total("wau"), "wau_prev": total("wau_prev"),
    "mau": total("mau"), "mau_prev": total("mau_prev"),
    "partial": len(have) < len(apps),
    "apps": apps,
    "url": next((a["url"] for a in have if a["url"]), None),
    "source": "ga4",
    "updated": now,
}
with open(os.path.join(board, "growth.json"), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY

python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "wrote $BOARD_DIR/growth.json"
