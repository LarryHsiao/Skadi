#!/usr/bin/env python3
"""appgrowth — a metis growth dashboard rendered into the Henneth window.

Usage: appgrowth.py

Queries the metis GA4 -> BigQuery export for active users, new users, and the
weekly trend, then renders an HTML dashboard into the Henneth previews folder:
DAU/WAU/MAU with week- and month-over-month deltas, a 12-week trend chart, and a
30-day daily sparkline. Reads from BigQuery within the free 1TB/month tier.

Configured for metis; override the project, dataset, and account with the
GROWTH_PROJECT, GROWTH_DATASET, and GROWTH_ACCOUNT environment variables.
"""

import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from pathlib import Path
from string import Template

PROJECT = os.environ.get("GROWTH_PROJECT", "metis-362623")
DATASET = os.environ.get("GROWTH_DATASET", "analytics_359632826")
GA_LAG_DAYS = 2            # GA4 daily tables finalize ~2 days late
TREND_WEEKS = 12
SPARK_DAYS = 30
MAX_BYTES = "1000000000"   # 1 GB scan cap (string for the bq flag) — metis is far under this
HENNETH = Path.home() / ".claude" / "previews" / "henneth"
OUT_HTML = HENNETH / "metis-growth.html"
OUT_JSON = HENNETH / "metis-growth.json"


def exe(name):
    """Resolve a CLI name to its full path — finds .cmd shims on Windows via PATHEXT."""
    return shutil.which(name) or name


def account():
    acct = os.environ.get("GROWTH_ACCOUNT")
    if acct:
        return acct
    out = subprocess.run([exe("firebase"), "login:list"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        for word in line.replace(",", " ").split():
            if "@" in word:
                return word.strip()
    return ""


def bq_rows(sql, acct):
    """Run a BigQuery query as the apps' account; rows as a list of dicts."""
    env = {**os.environ, "CLOUDSDK_CORE_ACCOUNT": acct} if acct else dict(os.environ)
    cmd = [exe("bq"), "query", f"--project_id={PROJECT}", "--use_legacy_sql=false",
           "--format=json", f"--maximum_bytes_billed={MAX_BYTES}", "--quiet", sql]
    out = subprocess.run(cmd, capture_output=True, text=True, env=env).stdout
    try:
        return json.loads(out or "[]")
    except ValueError:
        return []


def ymd(d):
    return d.strftime("%Y%m%d")


def fmt_day(ymd_str):
    d = datetime.strptime(ymd_str, "%Y%m%d")
    return f"{d.strftime('%b')} {d.day}"  # %-d is non-portable; d.day avoids it


def windows(anchor):
    """The four distinct-user windows, anchored on the last complete day."""
    return {
        "wau": (anchor - timedelta(days=6), anchor),
        "wau_prev": (anchor - timedelta(days=13), anchor - timedelta(days=7)),
        "mau": (anchor - timedelta(days=29), anchor),
        "mau_prev": (anchor - timedelta(days=59), anchor - timedelta(days=30)),
    }


def headline(acct, anchor):
    w = windows(anchor)

    def clause(key):
        a, b = w[key]
        return (f'COUNT(DISTINCT IF(event_date BETWEEN "{ymd(a)}" AND "{ymd(b)}", '
                f'user_pseudo_id, NULL)) AS {key}')

    lo, hi = ymd(w["mau_prev"][0]), ymd(w["mau"][1])
    sql = (f'SELECT {", ".join(clause(k) for k in w)} '
           f'FROM `{PROJECT}.{DATASET}.events_*` '
           f'WHERE _TABLE_SUFFIX BETWEEN "{lo}" AND "{hi}"')
    rows = bq_rows(sql, acct)
    return {k: int(rows[0].get(k, 0)) for k in w} if rows else {k: 0 for k in w}


def weekly(acct, anchor):
    lo = ymd(anchor - timedelta(weeks=TREND_WEEKS))
    sql = (f'SELECT DATE_TRUNC(PARSE_DATE("%Y%m%d", event_date), WEEK(MONDAY)) AS wk, '
           f'COUNT(DISTINCT user_pseudo_id) AS active, '
           f'COUNTIF(event_name="first_open") AS new_u '
           f'FROM `{PROJECT}.{DATASET}.events_*` '
           f'WHERE _TABLE_SUFFIX BETWEEN "{lo}" AND "{ymd(anchor)}" '
           f'GROUP BY wk ORDER BY wk')
    return bq_rows(sql, acct)


def daily(acct, anchor):
    lo = ymd(anchor - timedelta(days=SPARK_DAYS))
    sql = (f'SELECT event_date AS d, COUNT(DISTINCT user_pseudo_id) AS dau '
           f'FROM `{PROJECT}.{DATASET}.events_*` '
           f'WHERE _TABLE_SUFFIX BETWEEN "{lo}" AND "{ymd(anchor)}" '
           f'GROUP BY d ORDER BY d')
    return bq_rows(sql, acct)


def pct_word(cur, prev):
    if prev == 0:
        return "new" if cur else "flat"
    pct = round((cur - prev) / prev * 100)
    return f"up {pct}%" if pct > 0 else f"down {abs(pct)}%" if pct < 0 else "flat"


def delta(cur, prev):
    """A direction class and an arrow label for a headline card."""
    word = pct_word(cur, prev)  # "up 39%" | "down 58%" | "flat" | "new"
    if word.startswith("up"):
        return "up", "▲ " + word[3:]
    if word.startswith("down"):
        return "down", "▼ " + word[5:]
    return ("new" if word == "new" else "flat"), word


def points(values, vmax, x0=40, x1=700, ytop=20, ybot=220):
    if not values:
        return ""
    span = (x1 - x0) / (len(values) - 1) if len(values) > 1 else 0
    xs = [(x0 + x1) / 2] if len(values) == 1 else [x0 + i * span for i in range(len(values))]
    out = []
    for x, v in zip(xs, values):
        y = ybot - (v / vmax) * (ybot - ytop) if vmax else ybot
        out.append(f"{x:.0f},{y:.0f}")
    return " ".join(out)


def gridlines(vmax, x0=40, x1=700, ytop=20, ybot=220):
    lines, labels = [], []
    for i in range(5):
        y = ybot - (i / 4) * (ybot - ytop)
        lines.append(f'<line x1="{x0}" y1="{y:.0f}" x2="{x1}" y2="{y:.0f}"/>')
        labels.append(f'<text x="{x0 - 6}" y="{y + 3:.0f}" text-anchor="end">{round(i / 4 * vmax)}</text>')
    return "".join(lines), "".join(labels)


def xlabels(weeks, x0=40, x1=700, y=234):
    n = len(weeks)
    if not n:
        return ""
    span = (x1 - x0) / (n - 1) if n > 1 else 0
    out = []
    # four roughly-even ticks; the set collapses duplicates when n is small
    for i in sorted({0, n // 3, 2 * n // 3, n - 1}):
        x = (x0 + x1) / 2 if n == 1 else x0 + i * span
        out.append(f'<text x="{x:.0f}" y="{y}" text-anchor="middle">{weeks[i][5:]}</text>')
    return "".join(out)


def peak_marker(active, weeks, vmax, x0=40, x1=700, ytop=20, ybot=220):
    if not active:
        return ""
    i = active.index(max(active))
    span = (x1 - x0) / (len(active) - 1) if len(active) > 1 else 0
    x = (x0 + x1) / 2 if len(active) == 1 else x0 + i * span
    y = ybot - (active[i] / vmax) * (ybot - ytop) if vmax else ybot
    return (f'<circle cx="{x:.0f}" cy="{y:.0f}" r="4" fill="#7aa2f7"/>'
            f'<text x="{x:.0f}" y="{y - 6:.0f}" text-anchor="middle" fill="#e6e6e6">'
            f'{active[i]} · {weeks[i][5:]}</text>')


def read_line(h):
    return (f"Month-over-month: {pct_word(h['mau'], h['mau_prev'])} "
            f"(MAU {h['mau']} vs {h['mau_prev']}). "
            f"Week-over-week: {pct_word(h['wau'], h['wau_prev'])} "
            f"(WAU {h['wau']} vs {h['wau_prev']}).")


def render_page(h, wk, dl, anchor):
    active = [int(r["active"]) for r in wk]
    new_u = [int(r["new_u"]) for r in wk]
    weeks = [r["wk"] for r in wk]
    dau_series = [int(r["dau"]) for r in dl]
    vmax = max(active + new_u + [1])
    grid, ylab = gridlines(vmax)
    wau_cls, wau_txt = delta(h["wau"], h["wau_prev"])
    mau_cls, mau_txt = delta(h["mau"], h["mau_prev"])
    return PAGE.substitute(
        dau=dau_series[-1] if dau_series else 0,
        day=fmt_day(dl[-1]["d"]) if dl else fmt_day(ymd(anchor)),
        wau=h["wau"], wau_cls=wau_cls, wau_txt=wau_txt,
        mau=h["mau"], mau_cls=mau_cls, mau_txt=mau_txt,
        grid=grid, ylab=ylab,
        new_pts=points(new_u, vmax), active_pts=points(active, vmax),
        peak=peak_marker(active, weeks, vmax), xlab=xlabels(weeks),
        spark=points(dau_series, max(dau_series + [1]), x0=10, x1=274, ytop=5, ybot=45),
        weeks=len(weeks), anchor=fmt_day(ymd(anchor)), read=read_line(h))


def main():
    acct = account()
    if not acct:
        sys.exit("appgrowth: no account — set GROWTH_ACCOUNT or run `firebase login`.")
    anchor = date.today() - timedelta(days=GA_LAG_DAYS)
    with ThreadPoolExecutor(max_workers=3) as pool:
        f_h = pool.submit(headline, acct, anchor)
        f_w = pool.submit(weekly, acct, anchor)
        f_d = pool.submit(daily, acct, anchor)
        h, wk, dl = f_h.result(), f_w.result(), f_d.result()
    if not wk and not dl:
        sys.exit(f"appgrowth: no analytics rows for {PROJECT} — check access / dataset.")
    HENNETH.mkdir(parents=True, exist_ok=True)
    OUT_HTML.write_text(render_page(h, wk, dl, anchor), encoding="utf-8")
    OUT_JSON.write_text(json.dumps(
        {"title": "metis — Growth", "note": "live GA4 → BigQuery", "group": "metis-growth"}),
        encoding="utf-8")
    print(f"rendered {OUT_HTML}")
    print(f"  WAU {h['wau']} (prev {h['wau_prev']}) · MAU {h['mau']} (prev {h['mau_prev']})")
    return 0


PAGE = Template(r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>metis — Growth</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 16 16%22><text y=%2213%22 font-size=%2214%22>%F0%9F%93%88</text></svg>">
<style>
  :root{ --bg:#1e1e1e; --panel:#262626; --line:#3a3a3a; --ink:#e6e6e6; --muted:#8a8a8a;
    --accent:#7aa2f7; --up:#9ece6a; --down:#f7768e; }
  *{box-sizing:border-box;}
  body{margin:0;font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink);}
  .wrap{max-width:780px;margin:0 auto;padding:22px 20px 40px;}
  .top{display:flex;align-items:baseline;gap:10px;margin-bottom:4px;}
  .top h1{font-size:16px;letter-spacing:.04em;margin:0;color:var(--accent);font-weight:700;}
  .top .per{margin-left:auto;color:var(--muted);font-size:12px;}
  .sub{color:var(--muted);font-size:12.5px;margin:0 0 18px;}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:18px;}
  .card{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:14px 16px;}
  .card .k{color:var(--muted);font-size:11px;letter-spacing:.1em;text-transform:uppercase;}
  .card .v{font-size:30px;font-weight:700;margin:4px 0 2px;}
  .card .d{font-size:12.5px;font-weight:600;}
  .d.up{color:var(--up);} .d.down{color:var(--down);} .d.flat,.d.new{color:var(--muted);}
  .panelbox{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:14px 16px;margin-bottom:14px;}
  .panelbox h2{font-size:13px;margin:0 0 2px;letter-spacing:.03em;}
  .panelbox .cap{color:var(--muted);font-size:11.5px;margin:0 0 8px;}
  .legend{display:flex;gap:16px;font-size:11.5px;color:var(--muted);margin-bottom:6px;}
  .legend i{display:inline-block;width:18px;height:0;border-top:2px solid;vertical-align:middle;margin-right:5px;}
  svg text{fill:var(--muted);font-size:10px;}
  .read{border-left:3px solid var(--accent);background:#212530;border-radius:0 8px 8px 0;padding:10px 14px;color:#cdd3e6;font-size:12.5px;}
</style></head><body>
<div class="wrap">
  <div class="top"><span>&#9788;</span><h1>METIS · GROWTH</h1>
    <span class="per">$weeks weeks · through $anchor · GA4 → BigQuery</span></div>
  <p class="sub">Is the app gaining users? Active users, new users, and the trend that answers it.</p>
  <div class="cards">
    <div class="card"><div class="k">DAU · $day</div><div class="v">$dau</div><div class="d flat">daily active</div></div>
    <div class="card"><div class="k">WAU · last 7d</div><div class="v">$wau</div><div class="d $wau_cls">$wau_txt vs prior week</div></div>
    <div class="card"><div class="k">MAU · last 30d</div><div class="v">$mau</div><div class="d $mau_cls">$mau_txt vs prior month</div></div>
  </div>
  <div class="panelbox">
    <h2>Weekly trend</h2><p class="cap">Distinct active users and new users per week (Mon-start).</p>
    <div class="legend"><span><i style="border-color:#7aa2f7"></i>active users</span><span><i style="border-color:#9ece6a"></i>new users</span></div>
    <svg viewBox="0 0 720 240" width="100%" preserveAspectRatio="xMidYMid meet">
      <g stroke="#2e2e2e" stroke-width="1">$grid</g>
      <g>$ylab</g>
      <polyline fill="none" stroke="#9ece6a" stroke-width="2" stroke-opacity="0.85" points="$new_pts"/>
      <polyline fill="none" stroke="#7aa2f7" stroke-width="2.5" points="$active_pts"/>
      $peak
      <g>$xlab</g>
    </svg>
  </div>
  <div class="panelbox">
    <h2>Daily active users — last 30 days</h2><p class="cap">Recent texture.</p>
    <svg viewBox="0 0 290 52" width="290" height="52">
      <polyline fill="none" stroke="#7aa2f7" stroke-width="1.6" points="$spark"/>
    </svg>
  </div>
  <div class="read">$read</div>
</div></body></html>
""")


if __name__ == "__main__":
    sys.exit(main())
