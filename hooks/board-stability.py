#!/usr/bin/env python3
"""board-stability.py — crash-free users % for the board's Stability tile, by app.

Two collectors feed the board's Stability tile:

  - **App discovery** — every `crash_routing.md` any repo has ever bound (via
    `/beleg`), globbed across the configured Claude config roots
    (`~/.claude`, `~/.claude-personal`, `~/.claude-work`). A row now carries two
    optional trailing fields — GA4 project · dataset — alongside the six
    `/beleg` already writes (repo · flavor · Firebase project · bundle ·
    platform · account). `~/.skadi/board/stability-apps.json` layers hand-added
    or hand-corrected entries on top, keyed by the same label.
  - **The live number** — one BigQuery count against the Crashlytics export
    (crashed users) and, when an app carries a GA4 pairing, one against its
    GA4 export (active users), joined into a crash-free percentage.

Crashlytics and GA4 use different identifier spaces (`installation_uuid` vs
`user_pseudo_id`) — close enough in practice to read as one population, but
`crash_free_pct` clamps the crashed count to the active count so a mismatch
between them can never read as a negative crash-free rate.

Without a GA4 pairing there is no denominator, so `fetch()` returns
`crash_free_pct: None` with a `note` naming what's missing rather than
guessing — the same degrade-and-say-so discipline `beleg-crashes.py` uses for
a console-sourced ranking.

A third source, model-driven rather than mechanical: `sweep()` runs `fetch()`
across every app and separates the apps a number could be had for from the
ones that need `/beleg`'s Firebase-console scrape instead (`docs/plans/
board-stability-console-fallback.md`). `write()` takes what that scrape
found and shapes it into the same channel a board tile reads — this hook
never drives Chrome itself, only normalizes what the model brings back.
"""

import json
import os
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

from bq_common import QueryFailure, exe

CRASHLYTICS_DATASET = "firebase_crashlytics"
WINDOW_DAYS = 7             # matches the board tile's stated window
GA_LAG_DAYS = 2             # GA4 daily tables finalize ~2 days late (appgrowth.py's own lag)
MAX_BYTES = "1000000000"    # 1 GB scan cap — these are count-only queries

# STABILITY_APPS_PATH is a test seam — points local_apps() at a fixture file
# instead of the real board dir, the same override board.sh's BOARD_DIR gives.
STABILITY_APPS = Path(os.environ.get("STABILITY_APPS_PATH")
                       or Path.home() / ".skadi" / "board" / "stability-apps.json")
CONFIG_ROOTS = [Path.home() / ".claude", Path.home() / ".claude-personal", Path.home() / ".claude-work"]

BULLET_RE = re.compile(r"^-\s*(.+)$")


def table_id(bundle, platform):
    """The Crashlytics export's table name for one app on one platform."""
    flattened = re.sub(r"[^0-9A-Za-z]", "_", bundle)
    return f"{flattened}_{platform.upper()}"


def parse_crash_routing(text):
    """Every app row in one crash_routing.md body.

    Frontmatter and prose are ignored — only `- a | b | ...` bullets count. A
    row with neither six nor eight fields is skipped rather than raised on: a
    stray bullet elsewhere in the memory file must not sink every other app.
    """
    apps = []
    for line in text.splitlines():
        m = BULLET_RE.match(line.strip())
        if not m:
            continue
        fields = [f.strip() for f in m.group(1).split("|")]
        if len(fields) not in (6, 8):
            continue
        repo, flavor, project, bundle, platform, account = fields[:6]
        ga_project, ga_dataset = (fields[6], fields[7]) if len(fields) == 8 else (None, None)
        apps.append({
            "label": f"{Path(repo).name} · {flavor} · {platform.upper()}",
            "project": project,
            "bundle": bundle,
            "platform": platform.upper(),
            "account": account,
            "ga_project": ga_project or None,
            "ga_dataset": ga_dataset or None,
        })
    return apps


def merge_apps(discovered, local):
    """Discovered apps, with `stability-apps.json` entries overriding by label."""
    merged = {a["label"]: a for a in discovered if "label" in a}
    for a in local:
        if "label" in a:
            merged[a["label"]] = a
    return sorted(merged.values(), key=lambda a: a["label"])


def discover_apps():
    """Every app crash_routing.md binds, across every configured config root."""
    apps = []
    for root in CONFIG_ROOTS:
        projects = root / "projects"
        if not projects.is_dir():
            continue
        for memory_file in sorted(projects.glob("*/memory/crash_routing.md")):
            try:
                apps.extend(parse_crash_routing(memory_file.read_text(encoding="utf-8")))
            except OSError:
                continue
    return apps


def local_apps():
    """Hand-maintained overrides/additions — ~/.skadi/board/stability-apps.json."""
    if not STABILITY_APPS.is_file():
        return []
    try:
        data = json.loads(STABILITY_APPS.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return []
    return data if isinstance(data, list) else []


def list_apps():
    """Every app the Stability dropdown can offer, sorted by label."""
    return merge_apps(discover_apps(), local_apps())


def crashed_users_sql(project, dataset, table, days):
    return (f"SELECT COUNT(DISTINCT installation_uuid) AS n "
            f"FROM `{project}.{dataset}.{table}` "
            f"WHERE event_timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {days} DAY)")


def active_users_sql(ga_project, ga_dataset, bundle, days, anchor):
    """GA4's distinct-user count for one app over a `days`-wide window ending at `anchor`."""
    lo = (anchor - timedelta(days=days - 1)).strftime("%Y%m%d")
    hi = anchor.strftime("%Y%m%d")
    return (f"SELECT COUNT(DISTINCT user_pseudo_id) AS n "
            f"FROM `{ga_project}.{ga_dataset}.events_*` "
            f'WHERE _TABLE_SUFFIX BETWEEN "{lo}" AND "{hi}" '
            f'AND app_info.id = "{bundle}"')


def crash_free_pct(crashed_users, active_users):
    """1 − crashed/active as a percentage, or None with no denominator to read.

    `crashed_users` is clamped to `active_users` first — Crashlytics'
    `installation_uuid` and GA4's `user_pseudo_id` are different identifier
    spaces, and a mismatch between them must never read as a negative
    crash-free rate.
    """
    if active_users is None or active_users <= 0:
        return None
    crashed = min(max(crashed_users, 0), active_users)
    return round((1 - crashed / active_users) * 100, 1)


def label_slug(label):
    """A label as a filesystem-safe stem — lowercase, non-alnum runs to `-`.

    Labels carry spaces and a middle dot (`vitallink-ca · jp · ANDROID`),
    neither safe as a bare filename component across platforms.
    """
    slug = re.sub(r"[^0-9a-z]+", "-", label.lower()).strip("-")
    return slug


def bucket_by_availability(results):
    """Apps a live number could be had for, versus apps that need the scrape.

    `results` is `[(app, fetch_result), ...]` — the pairing `sweep()`
    produces. An app buckets into `needs_scrape` whenever its fetch result
    carries no `crash_free_pct`, whatever the reason (no GA4 pairing, no
    active users, or the query itself failed) — the console fallback is the
    same next step regardless of which.
    """
    ok, needs_scrape = [], []
    for app, result in results:
        (ok if result.get("crash_free_pct") is not None else needs_scrape).append(app)
    return {"ok": ok, "needs_scrape": needs_scrape}


def write(app, scraped):
    """A model-scraped console reading, shaped into the same channel a live
    fetch would have produced — `source` names it as the console's word, not
    BigQuery's."""
    return {"channel": "stability", "label": app["label"],
            "crash_free_pct": scraped.get("crash_free_pct"),
            "window_days": None, "source": "console",
            "note": scraped.get("note"), "slug": label_slug(app["label"])}


def bq_count(project, sql, account):
    """Run a single-row, single-column count query; the `n` column as an int."""
    env = {**os.environ, "CLOUDSDK_CORE_ACCOUNT": account} if account else dict(os.environ)
    try:
        done = subprocess.run(
            [exe("bq"), "query", f"--project_id={project}", "--use_legacy_sql=false",
             "--format=json", f"--maximum_bytes_billed={MAX_BYTES}", "--quiet", sql],
            capture_output=True, text=True, env=env)
    except FileNotFoundError:
        raise QueryFailure("the `bq` CLI is not on PATH — install the Google Cloud SDK")
    if done.returncode != 0:
        raise QueryFailure((done.stderr or done.stdout).strip() or f"bq exited {done.returncode}")
    try:
        rows = json.loads(done.stdout or "[]")
    except ValueError:
        raise QueryFailure(f"unparseable bq output: {done.stdout.strip()[:200]!r}")
    return int(rows[0]["n"]) if rows else 0


def fetch(app, window_days=WINDOW_DAYS, lag_days=GA_LAG_DAYS):
    """crash-free users % for one app entry, or a note naming what's missing."""
    table = table_id(app["bundle"], app["platform"])
    crashed = bq_count(app["project"],
                        crashed_users_sql(app["project"], CRASHLYTICS_DATASET, table, window_days),
                        app.get("account"))

    if not app.get("ga_project") or not app.get("ga_dataset"):
        return {"label": app["label"], "crash_free_pct": None, "crashed_users": crashed,
                "active_users": None, "window_days": window_days,
                "note": "GA4 not configured for this app — add ga_project/ga_dataset "
                        "to its crash_routing.md row or stability-apps.json entry"}

    anchor = date.today() - timedelta(days=lag_days)
    active = bq_count(app["ga_project"],
                       active_users_sql(app["ga_project"], app["ga_dataset"], app["bundle"],
                                         window_days, anchor),
                       app.get("account"))
    pct = crash_free_pct(crashed, active)
    return {"label": app["label"], "crash_free_pct": pct, "crashed_users": crashed,
            "active_users": active, "window_days": window_days,
            "note": None if pct is not None else "no active users in window"}


def sweep():
    """Every bound app, fetched, bucketed into ok versus needs a console scrape.

    A query failure buckets the same as a missing GA4 pairing — either way
    there is no number, and the next step is the same: `/beleg`'s scrape.
    """
    results = []
    for app in list_apps():
        try:
            results.append((app, fetch(app)))
        except QueryFailure as failure:
            results.append((app, {"crash_free_pct": None, "note": str(failure)}))
    return bucket_by_availability(results)


def format_sweep_report(bucketed):
    """`sweep()`'s bucket as the text `board.sh refresh --stability-scrape`
    prints — pure, so the report's shape is testable without the sweep's own
    BigQuery calls or board.sh's other refresh steps riding along."""
    needs = bucketed.get("needs_scrape") or []
    if not needs:
        return "board: stability — every bound app already has a live number, nothing to scrape"
    lines = [f"board: stability — {len(needs)} app(s) need a console scrape "
             "(BigQuery has no number for them):"]
    for a in needs:
        lines.append("  %-32s project=%s bundle=%s platform=%s account=%s" % (
            a.get("label", ""), a.get("project", ""), a.get("bundle", ""),
            a.get("platform", ""), a.get("account", "")))
    lines.append("Follow /beleg's console-scrape flow (SKILL.md §3) for each, then:")
    lines.append('  board.sh stability-write "<label>" --from-json <file>')
    return "\n".join(lines)


def _resolve_app(label):
    app = {a["label"]: a for a in list_apps()}.get(label)
    if app is None:
        sys.exit(f"board-stability: no app bound with label {label!r}")
    return app


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Board Stability tile — crash-free users % by app.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list-apps")
    sub.add_parser("sweep")
    sub.add_parser("sweep-report")
    fetch_p = sub.add_parser("fetch")
    fetch_p.add_argument("label")
    write_p = sub.add_parser("write")
    write_p.add_argument("label")
    write_p.add_argument("--from-json", dest="from_json", required=True)
    args = ap.parse_args(argv)

    if args.cmd == "list-apps":
        print(json.dumps(list_apps()))
        return 0

    if args.cmd == "sweep":
        print(json.dumps(sweep()))
        return 0

    if args.cmd == "sweep-report":
        print(format_sweep_report(sweep()))
        return 0

    if args.cmd == "write":
        app = _resolve_app(args.label)
        try:
            scraped = json.loads(Path(args.from_json).read_text(encoding="utf-8"))
        except (ValueError, OSError) as failure:
            sys.exit(f"board-stability: unreadable --from-json {args.from_json!r}: {failure}")
        print(json.dumps(write(app, scraped)))
        return 0

    # args.cmd == "fetch" — the last subcommand argparse's choices allow.
    app = _resolve_app(args.label)
    try:
        result = fetch(app)
    except QueryFailure as failure:
        sys.exit(f"board-stability: {failure}")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
