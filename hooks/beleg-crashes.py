#!/usr/bin/env python3
"""beleg — rank an app's Crashlytics issues by impact rather than volume.

The scoring here is deliberately blind to where its issues came from. Two
collectors feed it: the BigQuery Crashlytics export (structured, carries the
blaming frame) and a scrape of the Firebase console (thinner — no frame, often
no per-version split). A console-sourced ranking is still a ranking; it simply
rests on fewer signals, and `missing_signals` names which ones so the rendered
brief can say so rather than implying a completeness it does not have.

Issue shape (both collectors produce this):

    {"id", "title", "users", "events", "first_seen", "last_seen",
     "versions": [...] | absent, "latest_version": str | absent,
     "in_package": True|False|None,
     "blame_frame": {"file", "line", "symbol"} | None, "trend": str | absent}

`latest_version` is the app's newest known release, and the collector stamps it
onto every issue rather than passing it alongside. Only the collector knows it,
and carrying it on the issue keeps the scorer's signature to (issues, today) —
the alternative threads one more argument through every scoring function to say
the same thing.
"""

import json
import re
import shutil
import subprocess
from datetime import date, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUBRIC = json.loads((HERE / "beleg-rubric.json").read_text(encoding="utf-8"))

CRASHLYTICS_DATASET = "firebase_crashlytics"
WINDOW_DAYS = 60            # the export's own partition expiry — nothing older survives
MAX_BYTES = "5000000000"    # 5 GB scan cap; the tables seen so far are far under it
NO_EXPORT_EXIT = 2          # distinct from 1, so a caller can tell absence from failure
FIRST_PARTY_OWNER = "DEVELOPER"   # the export's word for a frame in your own code


class QueryFailure(RuntimeError):
    """A bq invocation that never ran the query — distinct from one returning no rows."""


class NoExport(RuntimeError):
    """The project carries no Crashlytics BigQuery export — the fallback's cue.

    Absence is not failure: the console still holds the crashes, so the skill
    reads this as "switch collectors", not "give up".
    """


def as_day(value):
    """Parse a YYYY-MM-DD stamp; a malformed one must not sink the whole ranking."""
    try:
        return datetime.strptime(str(value)[:10], "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return None


def trend_of(issue, today):
    """new / regressed / steady / fading — a collector's own verdict wins if it has one.

    Only the BigQuery source can tell a regression from a steady ache, since that
    needs per-version history. When it says so, its word stands over anything
    derived from dates alone.
    """
    stated = issue.get("trend")
    if stated in RUBRIC["trend"]:
        return stated
    first, last = as_day(issue.get("first_seen")), as_day(issue.get("last_seen"))
    if first and (today - first).days <= RUBRIC["new_within_days"]:
        return "new"
    if last and (today - last).days >= RUBRIC["fading_after_days"]:
        return "fading"
    return "steady"


def actionability_of(issue, rubric):
    """How far the blaming frame sits from code you can actually change.

    An absent verdict scores neutral, never a penalty: the console collector
    cannot see the frame at all, and silence is not evidence of a vendor fault.
    """
    weights = rubric["actionability"]
    in_package = issue.get("in_package")
    if in_package is None:
        return weights["unknown"]
    return weights["in_package"] if in_package else weights["third_party"]


def concentration_of(issue, rubric):
    """A crash confined to the newest build is a shipped regression, not an ache."""
    weights = rubric["version_concentration"]
    versions = issue.get("versions") or []
    latest = issue.get("latest_version")
    if not versions or not latest:
        return weights["spread"]
    return weights["latest_only"] if set(versions) == {latest} else weights["spread"]


def value_of(issue, today):
    """The four signals multiplied — blast radius, freshness, confinement, reach."""
    users = max(int(issue.get("users") or 0), 0)
    blast = users ** RUBRIC["users_exponent"]
    return (blast
            * RUBRIC["trend"][trend_of(issue, today)]
            * concentration_of(issue, RUBRIC)
            * actionability_of(issue, RUBRIC))


def rank(issues, today=None):
    """Issues newly stamped with `value` and `trend`, heaviest first."""
    day = today or date.today()
    scored = [{**i, "value": value_of(i, day), "trend": trend_of(i, day)}
              for i in issues]
    return sorted(scored, key=lambda i: i["value"], reverse=True)


def table_id(bundle, platform):
    """The export's table name for one app on one platform.

    Firebase flattens every character that cannot sit in a BigQuery identifier,
    so `com.jubohealth.vitallink-ca` on iOS becomes
    `com_jubohealth_vitallink_ca_IOS`.
    """
    flattened = re.sub(r"[^0-9A-Za-z]", "_", bundle)
    return f"{flattened}_{platform.upper()}"


def issue_from_row(row, latest_version):
    """One grouped query row as the issue shape the scorer reads.

    `blame_frame.owner` is the export's own judgement of who can fix a crash, so
    actionability is read from it rather than guessed from a package prefix. An
    absent owner stays None — unknown, and neutral in the scoring.
    """
    owner = row.get("blame_owner")
    frame = None
    if row.get("blame_file"):
        frame = {"file": row["blame_file"],
                 "line": int(row.get("blame_line") or 0),
                 "symbol": row.get("blame_symbol") or ""}
    return {
        "id": row.get("issue_id"),
        "title": row.get("issue_title") or "",
        "subtitle": row.get("issue_subtitle") or "",
        "users": int(row.get("users") or 0),
        "events": int(row.get("events") or 0),
        "first_seen": (row.get("first_seen") or "")[:10],
        "last_seen": (row.get("last_seen") or "")[:10],
        "versions": [v for v in (row.get("versions") or "").split(",") if v],
        "latest_version": latest_version,
        "in_package": None if not owner else owner == FIRST_PARTY_OWNER,
        "blame_frame": frame,
    }


def missing_signals(issues):
    """Which ranking signals this batch could not supply, for the brief to declare.

    Read across the whole batch, not per issue: one issue lacking a frame is
    ordinary, but a batch where none carries one means the collector could not
    see frames at all.
    """
    absent = []
    if all(i.get("in_package") is None for i in issues):
        absent.append("actionability")
    if all(not i.get("versions") or not i.get("latest_version") for i in issues):
        absent.append("version concentration")
    return absent


def exe(name):
    """Resolve a CLI name to its full path — finds .cmd shims on Windows via PATHEXT."""
    return shutil.which(name) or name


def bq(args, account):
    """Run a bq subcommand as the given account; stdout on success.

    Every failure is named rather than folded into an empty result — the lesson
    appgrowth.py paid for, where a refused query and an empty dataset wore the
    same face for weeks.
    """
    import os
    env = {**os.environ, "CLOUDSDK_CORE_ACCOUNT": account} if account else dict(os.environ)
    try:
        done = subprocess.run([exe("bq"), *args], capture_output=True, text=True, env=env)
    except FileNotFoundError:
        raise QueryFailure("the `bq` CLI is not on PATH — install the Google Cloud SDK")
    if done.returncode != 0:
        raise QueryFailure((done.stderr or done.stdout).strip() or f"bq exited {done.returncode}")
    return done.stdout


def require_export(project, account):
    """Raise NoExport when the project carries no Crashlytics dataset.

    Probed with `bq show` rather than inferred from an empty query, so absence
    is distinguished from a query that ran and found nothing.
    """
    try:
        bq(["show", "--format=none", f"{project}:{CRASHLYTICS_DATASET}"], account)
    except QueryFailure as failure:
        if "not found" in str(failure).lower():
            raise NoExport(
                f"{project} has no `{CRASHLYTICS_DATASET}` dataset — the Crashlytics "
                "BigQuery export is not switched on (it back-fills nothing, so enable "
                "it before the crashes you want are past the 60-day horizon)")
        raise


ISSUE_SQL = """
SELECT issue_id,
       ANY_VALUE(issue_title) AS issue_title,
       ANY_VALUE(issue_subtitle) AS issue_subtitle,
       COUNT(DISTINCT installation_uuid) AS users,
       COUNT(*) AS events,
       CAST(MIN(DATE(event_timestamp)) AS STRING) AS first_seen,
       CAST(MAX(DATE(event_timestamp)) AS STRING) AS last_seen,
       STRING_AGG(DISTINCT application.display_version) AS versions,
       ANY_VALUE(blame_frame.file) AS blame_file,
       ANY_VALUE(blame_frame.line) AS blame_line,
       ANY_VALUE(blame_frame.symbol) AS blame_symbol,
       ANY_VALUE(blame_frame.owner) AS blame_owner
FROM `{project}.{dataset}.{table}`
WHERE event_timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {days} DAY)
GROUP BY issue_id
"""


def collect(project, bundle, platform, account):
    """Every issue in the export's window, in the scorer's shape."""
    require_export(project, account)
    sql = ISSUE_SQL.format(project=project, dataset=CRASHLYTICS_DATASET,
                           table=table_id(bundle, platform), days=WINDOW_DAYS)
    out = bq(["query", f"--project_id={project}", "--use_legacy_sql=false",
              "--format=json", f"--maximum_bytes_billed={MAX_BYTES}", "--quiet", sql],
             account)
    try:
        rows = json.loads(out or "[]")
    except ValueError:
        raise QueryFailure(f"unparseable bq output: {out.strip()[:200]!r}")
    latest = newest_version(rows)
    return [issue_from_row(r, latest) for r in rows]


HENNETH = Path.home() / ".claude" / "previews" / "henneth"
TOP_N = 12


def render_page(brief):
    """The ranked brief as one self-contained page for the Henneth window.

    The caveat line is not decoration: a ranking computed without the blaming
    frame rests on fewer signals than one computed with it, and the page says
    which were missing rather than letting the reader assume completeness.
    """
    absent = brief["missing_signals"]
    caveat = (f"<p class=gap>Ranked without: {', '.join(absent)} — "
              f"this source could not supply them.</p>") if absent else ""
    rows = "\n".join(
        f"<tr><td class=v>{i['value']:.0f}</td><td>{esc(i['title'])}</td>"
        f"<td>{i['trend']}</td><td class=v>{i['users']}</td>"
        f"<td class=f>{frame_label(i)}</td></tr>"
        for i in brief["issues"][:TOP_N])
    return f"""<meta charset="utf-8">
<title>Beleg — crashes by value</title>
<link rel="stylesheet" href="skadi-theme.css">
<style>
 body{{font:14px/1.5 -apple-system,system-ui,sans-serif;padding:2rem;max-width:60rem}}
 table{{border-collapse:collapse;width:100%}} th,td{{padding:.4rem .6rem;text-align:left}}
 thead th{{border-bottom:2px solid currentColor}} tr+tr td{{border-top:1px solid #8883}}
 .v{{text-align:right;font-variant-numeric:tabular-nums}}
 .f{{font-family:ui-monospace,monospace;font-size:.85em;opacity:.8}}
 .gap{{opacity:.75;font-style:italic}}
</style>
<h1>Crashes by value</h1>
<p>Source: <b>{esc(brief['source'])}</b> · window {brief['window_days']} days ·
   {len(brief['issues'])} issue(s)</p>
{caveat}
<table><thead><tr><th class=v>value</th><th>issue</th><th>trend</th>
<th class=v>users</th><th>blaming frame</th></tr></thead>
<tbody>{rows}</tbody></table>
"""


def esc(text):
    """Minimal HTML escaping — crash titles carry angle brackets and ampersands."""
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def frame_label(issue):
    """`file:line` for the brief, or an em dash when the source saw no frame."""
    frame = issue.get("blame_frame")
    return f"{esc(frame['file'])}:{frame['line']}" if frame else "—"


def main(argv):
    """Collect (or read) issues, rank them, and print the brief as JSON.

    Exits NO_EXPORT_EXIT when the project has no export, so the skill can tell
    "switch to the console collector" from "the query failed".
    """
    import argparse
    ap = argparse.ArgumentParser(description="Rank Crashlytics issues by impact.")
    ap.add_argument("--project"), ap.add_argument("--bundle")
    ap.add_argument("--platform", default="ANDROID"), ap.add_argument("--account")
    ap.add_argument("--from-json", dest="from_json",
                    help="rank issues collected elsewhere (the console fallback)")
    args = ap.parse_args(argv)
    if args.from_json:
        payload = json.loads(Path(args.from_json).read_text(encoding="utf-8"))
        issues, source = payload.get("issues", []), payload.get("source", "console")
    else:
        if not (args.project and args.bundle):
            ap.error("--project and --bundle are required without --from-json")
        issues, source = collect(args.project, args.bundle, args.platform,
                                 args.account), "bigquery"
    brief = {"source": source, "window_days": WINDOW_DAYS,
             "missing_signals": missing_signals(issues), "issues": rank(issues)}
    HENNETH.mkdir(parents=True, exist_ok=True)
    out = HENNETH / "beleg-crashes.html"
    out.write_text(render_page(brief), encoding="utf-8")
    (HENNETH / "beleg-crashes.json").write_text(json.dumps(
        {"title": "Beleg — crashes by value",
         "note": f"{source} · {len(brief['issues'])} issue(s)",
         "group": "beleg"}), encoding="utf-8")
    print(f"rendered {out}")
    print(f"  {len(brief['issues'])} issue(s) from {source}"
          + (f" · missing: {', '.join(brief['missing_signals'])}"
             if brief["missing_signals"] else ""))
    return 0


def newest_version(rows):
    """The highest display_version the batch mentions, compared numerically.

    A string sort would rank "1.9.0" above "1.10.0"; the concentration weight
    turns on getting this right, so the comparison is by numeric parts.
    """
    seen = set()
    for row in rows:
        seen.update(v for v in (row.get("versions") or "").split(",") if v)
    if not seen:
        return ""
    return max(seen, key=lambda v: [int(p) if p.isdigit() else 0 for p in v.split(".")])


if __name__ == "__main__":
    import sys
    try:
        sys.exit(main(sys.argv[1:]))
    except NoExport as absent:
        # Absence is not failure — NO_EXPORT_EXIT tells the skill to switch
        # collectors rather than to give up.
        print(f"beleg: {absent}", file=sys.stderr)
        sys.exit(NO_EXPORT_EXIT)
    except QueryFailure as failure:
        sys.exit(f"beleg: {failure}")
