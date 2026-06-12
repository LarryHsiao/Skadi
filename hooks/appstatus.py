#!/usr/bin/env python3
"""appstatus — a cross-app Firebase health snapshot from Cloud Monitoring.

Usage: appstatus.py

Prints one table of usage/health signals — Firestore reads/writes, Cloud
Functions calls and errors, Storage — across the firebase account's apps over
the last 24h. Read-only; Monitoring reads sit inside the free tier, so it costs
nothing.

The account defaults to whichever Google account `firebase` is logged in as
(the one that owns the apps), so the snapshot reads the apps' owner and never
falls back to a different active gcloud login. Override with APPSTATUS_ACCOUNT.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

WINDOW_HOURS = 24
TIMESERIES = "https://monitoring.googleapis.com/v3/projects/{}/timeSeries"
WORKERS = 8
ERROR_COL = "Fn errors"
STORAGE_COL = "Storage GB"

# (column, metric.type, extra filter, per-series aligner)
METRICS = [
    ("Firestore rd", "firestore.googleapis.com/document/read_count", "", "ALIGN_SUM"),
    ("Firestore wr", "firestore.googleapis.com/document/write_count", "", "ALIGN_SUM"),
    ("Fn calls", "cloudfunctions.googleapis.com/function/execution_count", "", "ALIGN_SUM"),
    (ERROR_COL, "cloudfunctions.googleapis.com/function/execution_count",
     ' AND metric.label.status!="ok"', "ALIGN_SUM"),
    (STORAGE_COL, "storage.googleapis.com/storage/total_bytes", "", "ALIGN_MEAN"),
]


def _run(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def default_account():
    """The Google account firebase is logged in as — the owner of the apps."""
    for line in _run(["firebase", "login:list"]).splitlines():
        for word in line.replace(",", " ").split():
            if "@" in word:
                return word.strip()
    return ""


def access_token(account):
    tok = _run(["gcloud", "auth", "print-access-token", "--account", account]).strip()
    if not tok:
        sys.exit(f"appstatus: no access token for {account}.\n"
                 f"  run:  gcloud auth login {account}")
    return tok


def project_ids():
    """The account's Firebase apps (not every GCP project — drops sample/demo)."""
    out = _run(["firebase", "projects:list", "--json"])
    try:
        result = json.loads(out).get("result", [])
        return sorted(p["projectId"] for p in result if p.get("projectId"))
    except (ValueError, KeyError, TypeError, AttributeError):
        return []


def _sum_points(data):
    """Sum every point across all time series in a Monitoring response."""
    total = 0.0
    for series in data.get("timeSeries", []):
        for point in series.get("points", []):
            value = point.get("value", {})
            raw = value.get("int64Value", value.get("doubleValue", 0))
            total += float(raw or 0)
    return total


def metric_total(token, project, metric, extra, aligner, start, end):
    """Sum a metric over the window for one project; None on any read error."""
    params = {
        "filter": f'metric.type="{metric}"{extra}',
        "interval.startTime": start,
        "interval.endTime": end,
        "aggregation.alignmentPeriod": f"{WINDOW_HOURS * 3600}s",
        "aggregation.perSeriesAligner": aligner,
    }
    url = TIMESERIES.format(project) + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, ValueError, TimeoutError):
        return None
    return _sum_points(data)


def humanize(column, n):
    if n is None:
        return "n/a"
    if column == STORAGE_COL:
        return f"{n / 1e9:.2f}"
    if n >= 1000:
        return f"{n:,.0f}"
    return f"{n:.0f}"


def collect_grid(token, projects, start, end):
    """Map project -> {column: total} by fetching every cell concurrently."""
    grid = {p: {} for p in projects}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {}
        for project in projects:
            for column, metric, extra, aligner in METRICS:
                future = pool.submit(
                    metric_total, token, project, metric, extra, aligner, start, end)
                futures[future] = (project, column)
        for future, (project, column) in futures.items():
            grid[project][column] = future.result()
    return grid


def render(projects, grid, end_iso, account):
    columns = [m[0] for m in METRICS]
    name_w = max([len(p) for p in projects] + [len("PROJECT")])
    col_w = 13
    width = name_w + 2 + len(columns) * col_w
    print(f"App Status — Firebase health, last {WINDOW_HOURS}h          {end_iso}")
    print("-" * width)
    print("PROJECT".ljust(name_w) + "  " + "".join(c.rjust(col_w) for c in columns))
    for project in projects:
        cells = []
        for column in columns:
            value = humanize(column, grid[project][column])
            if column == ERROR_COL and grid[project][column]:
                value += " !"
            cells.append(value.rjust(col_w))
        print(project.ljust(name_w) + "  " + "".join(cells))
    print()
    print(f"account {account}  -  read-only  -  Cloud Monitoring (free tier)")


def main():
    account = os.environ.get("APPSTATUS_ACCOUNT") or default_account()
    if not account:
        sys.exit("appstatus: no account — set APPSTATUS_ACCOUNT or run `firebase login`.")
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=WINDOW_HOURS)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    token = access_token(account)
    projects = project_ids()
    if not projects:
        sys.exit(f"appstatus: no Firebase apps found for {account}")
    grid = collect_grid(token, projects, start.strftime(fmt), end.strftime(fmt))
    render(projects, grid, end.strftime(fmt), account)
    return 0


if __name__ == "__main__":
    sys.exit(main())
