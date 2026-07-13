#!/usr/bin/env python3
"""fidelity-scan.py — the plan-fidelity engine.

Reads the raw /mandos verdict history (mandos-record.sh appends one line per
verdict — see skills/mandos/SKILL.md's Record step), reduces it to a Faithful
rate and a Missing-vs-Scope-crept split, then writes a board-channel snapshot
and a self-contained Henneth dashboard. Unlike pulse-scan.py, there is no
separate per-run history to append to — each /mandos verdict is already one
stamped record, so the trend is cut directly from mandos-record.sh's output.

Test seams: MANDOS_HISTORY_DIR overrides the history folder; BOARD_DIR /
HENNETH_DIR override the output folders.
"""
import json
import os
import sys


def read_records(history_path):
    """Ordered verdict records; torn lines skipped, not fatal."""
    records = []
    if not os.path.exists(history_path):
        return records
    with open(history_path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except ValueError:
                continue  # torn write — skip, don't blank the run
    return records


def _bucket_sum(record, bucket):
    values = record.get(bucket) or {}
    if not isinstance(values, dict):
        return 0
    return sum(v for v in values.values() if isinstance(v, (int, float)))


def summarize(records):
    """Headline stats: the Faithful rate, and the Missing/Scope-crept split —
    Blocker-severity counts, since only Blockers gate the /mandos tier and so
    only Blockers explain why a verdict fell short of Faithful."""
    total = len(records)
    faithful = sum(1 for r in records if r.get("tier") == "Faithful")
    rate = round(100 * faithful / total) if total else None
    missing_blockers = sum((r.get("missing") or {}).get("blocker", 0) or 0 for r in records)
    scope_blockers = sum((r.get("scope") or {}).get("blocker", 0) or 0 for r in records)
    return {
        "total": total,
        "faithful": faithful,
        "rate": rate,
        "missingBlockers": missing_blockers,
        "scopeBlockers": scope_blockers,
    }


def trend_series(records):
    """Cumulative Faithful rate after each record, in ts order — the line the
    dashboard plots. Records lacking a usable ts sort last, stable otherwise."""
    ordered = sorted(records, key=lambda r: r.get("ts") or "")
    series = []
    faithful = 0
    for i, r in enumerate(ordered, start=1):
        if r.get("tier") == "Faithful":
            faithful += 1
        series.append({"ts": r.get("ts", ""), "rate": round(100 * faithful / i)})
    return series


def write_outputs(headline, series, board_dir, henneth_dir, now_iso, door):
    os.makedirs(board_dir, exist_ok=True)
    snapshot = {
        "channel": "fidelity",
        "headline": headline,
        "series": series,
        "updated": now_iso,
        "url": door,
        "source": "fidelity-scan",
    }
    with open(os.path.join(board_dir, "fidelity.json"), "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh, ensure_ascii=False, indent=2)


def render_dashboard(headline, series, henneth_dir, now_iso):
    """A self-contained Henneth page: four stat tiles plus a plain inline-SVG
    polyline trend — the data model here is one rate and two counts, not the
    many rubric rows pulse-scan.py plots, so no charting library is warranted."""
    data = json.dumps({"headline": headline, "series": series, "ts": now_iso})
    html = _PAGE.replace("/*DATA*/", data)
    try:
        os.makedirs(henneth_dir, exist_ok=True)
        with open(os.path.join(henneth_dir, "plan-fidelity.html"), "w", encoding="utf-8") as fh:
            fh.write(html)
    except OSError as err:
        print("fidelity-scan: cannot render dashboard: %s" % err, file=sys.stderr)
        return None
    return "plan-fidelity.html"


_PAGE = """<meta charset="utf-8">
<title>Plan Fidelity</title>
<style>
  body { font: 14px/1.5 -apple-system, sans-serif; margin: 2rem; color: #222; background: #fff; }
  @media (prefers-color-scheme: dark) { body { color: #eee; background: #1a1a1a; } }
  h1 { font-size: 1.1rem; font-weight: 600; }
  .tiles { display: flex; gap: 1rem; flex-wrap: wrap; margin: 1.5rem 0; }
  .tile { border: 1px solid #8884; border-radius: 8px; padding: 0.75rem 1rem; min-width: 8rem; }
  .tile .n { font-size: 1.6rem; font-weight: 700; }
  .tile .l { opacity: 0.7; font-size: 0.8rem; }
  svg { max-width: 100%; }
  .empty { opacity: 0.6; }
</style>
<h1>Plan Fidelity — /mandos verdicts reduced to a rate</h1>
<div id="app"></div>
<script>
const DATA = /*DATA*/;
const app = document.getElementById("app");
const h = DATA.headline;
if (!h.total) {
  app.innerHTML = '<p class="empty">No /mandos verdicts recorded yet — the rate fills in as /mandos runs.</p>';
} else {
  const tiles = [
    ["Faithful rate", h.rate + "%"],
    ["Verdicts weighed", h.total],
    ["Missing blockers", h.missingBlockers],
    ["Scope-crept blockers", h.scopeBlockers],
  ];
  const tileHtml = tiles.map(([l, n]) =>
    `<div class="tile"><div class="n">${n}</div><div class="l">${l}</div></div>`
  ).join("");
  let trendHtml = "";
  if (DATA.series.length > 1) {
    const w = 480, ht = 80, pad = 4;
    const pts = DATA.series.map((p, i) => {
      const x = pad + (i / (DATA.series.length - 1)) * (w - 2 * pad);
      const y = ht - pad - (p.rate / 100) * (ht - 2 * pad);
      return x.toFixed(1) + "," + y.toFixed(1);
    }).join(" ");
    trendHtml = `<h2 style="font-size:0.9rem;opacity:0.8;">Cumulative Faithful rate</h2>
      <svg viewBox="0 0 ${w} ${ht}" width="${w}" height="${ht}">
        <polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="2"/>
      </svg>`;
  }
  app.innerHTML = `<div class="tiles">${tileHtml}</div>${trendHtml}`;
}
</script>
"""


def main():
    from datetime import datetime, timezone
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    history_dir = os.environ.get("MANDOS_HISTORY_DIR", os.path.expanduser("~/.skadi/mandos"))
    board_dir = os.environ.get("BOARD_DIR", os.path.expanduser("~/.skadi/board"))
    henneth_dir = os.environ.get("HENNETH_DIR", os.path.expanduser("~/.claude/previews/henneth"))
    records = read_records(os.path.join(history_dir, "history.jsonl"))
    headline = summarize(records)
    series = trend_series(records)
    door = render_dashboard(headline, series, henneth_dir, now_iso)
    write_outputs(headline, series, board_dir, henneth_dir, now_iso, door)
    print("plan fidelity: %s%% faithful across %d verdicts" %
          (headline["rate"] if headline["rate"] is not None else "—", headline["total"]))


if __name__ == "__main__":
    main()
