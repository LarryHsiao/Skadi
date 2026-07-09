#!/usr/bin/env python3
"""pulse-scan.py — the adherence pulse engine.

Walks every config root's projects/**/*.jsonl (read-only), applies the
declarative rubric (pulse-rubric.json), and writes a per-run history line, a
board-channel snapshot, and a self-contained Henneth dashboard.

Test seams: PULSE_ROOTS (colon-separated fixture roots) overrides the config
roots; PULSE_DIR / BOARD_DIR / HENNETH_DIR override the output folders.
"""
import glob
import json
import os
import re
import sys

WINDOW_DAYS = 30
SECONDS_PER_DAY = 86400


def _turn_text(message):
    """The concatenated text of a turn — user string content or assistant text blocks."""
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def read_turns(path):
    """Ordered turns from one transcript; torn lines skipped, not fatal."""
    turns = []
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError as err:
        print("pulse-scan: cannot open %s: %s" % (path, err), file=sys.stderr)
        return turns
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue  # torn write — skip, don't blank the session
            t = d.get("type")
            if t not in ("user", "assistant"):
                continue
            turns.append({
                "type": t,
                "text": _turn_text(d.get("message", {})),
                "ts": d.get("timestamp", ""),
            })
    return turns


def session_files(roots, window_days, now_epoch):
    """Every projects/*/*.jsonl across roots whose mtime is within the window."""
    cutoff = now_epoch - window_days * SECONDS_PER_DAY
    found = []
    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for path in glob.glob(os.path.join(root, "projects", "*", "*.jsonl")):
            try:
                if os.path.getmtime(path) >= cutoff:
                    found.append(path)
            except OSError:
                continue
    return found


def _is_prompt(text):
    """A genuine user prompt — not a slash command, a harness injection, or a
    tool result. Skill runs inject their body as a user turn ("Base directory
    for this skill:"), and tool results are empty user turns; a naive
    'next user turn' boundary would see an empty run, so those are skipped."""
    if not text:
        return False
    noise = ("<command-name>", "<command-message>", "<command-args>",
             "Base directory for this skill:", "<local-command-stdout>",
             "<local-command-caveat>")
    return not any(tok in text for tok in noise)


def _ends_run(turn):
    """A run ends at a genuine user prompt or a new command invocation."""
    return turn["type"] == "user" and (
        _is_prompt(turn["text"]) or "<command-name>" in turn["text"])


def score_workflow(turns, entry):
    """applied = invocations; complied = runs where the verdict token appears."""
    applies = re.compile(entry["applies"])
    complied_re = re.compile(entry["complied"])
    applied = 0
    complied = 0
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and applies.search(turn["text"]):
            applied += 1
            j = i + 1
            run_text = []
            while j < n and not _ends_run(turns[j]):
                if turns[j]["type"] == "assistant":
                    run_text.append(turns[j]["text"])
                j += 1
            if complied_re.search("\n".join(run_text)):
                complied += 1
            i = j
            continue
        i += 1
    return applied, complied


def score_grammar(turns, entry):
    """applied = genuine user prompts; complied = those whose run drew no grammar note."""
    marker = re.compile(entry["complied"])
    applied = 0
    complied = 0
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and _is_prompt(turn["text"]):
            applied += 1
            j = i + 1
            run_text = []
            while j < n and not _ends_run(turns[j]):
                if turns[j]["type"] == "assistant":
                    run_text.append(turns[j]["text"])
                j += 1
            if not marker.search("\n".join(run_text)):
                complied += 1
            i = j
            continue
        i += 1
    return applied, complied


def _rate(applied, complied):
    return round(100 * complied / applied) if applied else None


def apply_rubric(files, rubric):
    """One result per rubric entry, aggregated across every session file."""
    scorers = {"workflow": score_workflow, "grammar": score_grammar}
    sessions = [read_turns(f) for f in files]
    items = []
    for entry in rubric:
        kind = entry["kind"]
        base = {"id": entry["id"], "label": entry["label"],
                "tier": entry["tier"], "kind": kind}
        if kind not in scorers:  # git-probe / forge-probe — not built yet
            items.append({**base, "applied": None, "complied": None,
                          "rate": None, "status": "pending"})
            continue
        try:
            applied = complied = 0
            for turns in sessions:
                a, c = scorers[kind](turns, entry)
                applied += a
                complied += c
            items.append({**base, "applied": applied, "complied": complied,
                          "rate": _rate(applied, complied), "status": "ok"})
        except re.error as err:
            print("pulse-scan: %s matcher error: %s" % (entry["id"], err), file=sys.stderr)
            items.append({**base, "applied": None, "complied": None,
                          "rate": None, "status": "error"})
    return items


def _overall(items):
    rates = [i["rate"] for i in items if isinstance(i.get("rate"), (int, float))]
    return round(sum(rates) / len(rates)) if rates else None


def _by_tier(items):
    """Mean rate per tier, over items with a numeric rate — so the headline
    never rests on a single cross-tier number."""
    buckets = {}
    for i in items:
        if isinstance(i.get("rate"), (int, float)):
            buckets.setdefault(i["tier"], []).append(i["rate"])
    return {t: round(sum(v) / len(v)) for t, v in buckets.items()}


def _prev_overall(history_path):
    if not os.path.exists(history_path):
        return None
    last = None
    with open(history_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                last = line
    if not last:
        return None
    try:
        return json.loads(last).get("overall")
    except ValueError:
        return None


def write_outputs(items, pulse_dir, board_dir, now_iso, window_days, door):
    os.makedirs(pulse_dir, exist_ok=True)
    os.makedirs(board_dir, exist_ok=True)
    history_path = os.path.join(pulse_dir, "history.jsonl")
    overall = _overall(items)
    prev = _prev_overall(history_path)
    delta = (overall - prev) if (overall is not None and prev is not None) else None
    with open(history_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"ts": now_iso, "window": window_days,
                             "overall": overall, "items": items},
                            ensure_ascii=False) + "\n")
    snapshot = {
        "channel": "pulse",
        "headline": {"overall": overall, "delta": delta, "byTier": _by_tier(items)},
        "items": items,
        "updated": now_iso,
        "url": door,
        "source": "pulse-scan",
    }
    with open(os.path.join(board_dir, "pulse.json"), "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh, ensure_ascii=False, indent=2)


def _default_roots():
    override = os.environ.get("PULSE_ROOTS")
    if override:
        return override.split(":")
    return ["~/.claude", "~/.claude-personal", "~/.claude-work"]


def _history_overalls(pulse_dir):
    path = os.path.join(pulse_dir, "history.jsonl")
    series = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec.get("overall"), (int, float)):
                    series.append(rec["overall"])
    return series


def render_dashboard(items, pulse_dir, henneth_dir, now_iso):
    """A self-contained Henneth page with the scorecard + trend inlined."""
    series = _history_overalls(pulse_dir) + [_overall(items)]
    series = [s for s in series if isinstance(s, (int, float))]
    data = json.dumps({"items": items, "series": series, "ts": now_iso})
    html = _PAGE.replace("/*DATA*/", data)
    try:
        os.makedirs(henneth_dir, exist_ok=True)
        with open(os.path.join(henneth_dir, "adherence-pulse.html"), "w", encoding="utf-8") as fh:
            fh.write(html)
    except OSError as err:
        print("pulse-scan: cannot render dashboard: %s" % err, file=sys.stderr)
        return None
    return "adherence-pulse.html"


_PAGE = """<meta charset="utf-8">
<link rel="stylesheet" href="skadi-theme.css">
<title>Adherence Pulse</title>
<style>
  body{font-family:ui-sans-serif,system-ui,sans-serif;margin:1.2rem;}
  .kpi{font-size:2.4rem;font-weight:700;}
  .avglabel{font-size:.62rem;text-transform:uppercase;letter-spacing:.06em;color:#87795e;margin-top:-.3rem;}
  .tiers{display:flex;gap:.6rem;margin:.4rem 0;flex-wrap:wrap;}
  .tierchip{border:1px solid #cbb89a;border-radius:6px;padding:.25rem .55rem;font-size:.8rem;}
  .tierchip b{font-size:1.1rem;}
  table{border-collapse:collapse;width:100%;margin-top:1rem;font-size:.85rem;}
  th,td{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #cbb89a;}
  .badge{font-size:.6rem;text-transform:uppercase;border:1px solid #cbb89a;border-radius:999px;padding:.05rem .4rem;}
  .pending{opacity:.5;} .meter{height:6px;background:#e2d6bb;border-radius:999px;overflow:hidden;}
  .meter i{display:block;height:100%;background:#7a5c2e;}
</style>
<h1>Adherence Pulse</h1>
<div class="tiers" id="tiers"></div>
<div class="kpi" id="overall">—</div>
<div class="avglabel">cross-tier average</div>
<svg id="spark" width="320" height="40"></svg>
<table id="rows"></table>
<script>
const DATA = /*DATA*/;
const esc = (s) => String(s == null ? "" : s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const rated = DATA.items.filter(i => typeof i.rate === "number");
const overall = rated.length ? Math.round(rated.reduce((a,i)=>a+i.rate,0)/rated.length) : null;
document.getElementById("overall").textContent = overall == null ? "—" : overall + "%";
const byTier = {};
rated.forEach(i => { (byTier[i.tier] = byTier[i.tier] || []).push(i.rate); });
document.getElementById("tiers").innerHTML = Object.keys(byTier).sort().map(t => {
  const avg = Math.round(byTier[t].reduce((a,v)=>a+v,0)/byTier[t].length);
  return `<span class="tierchip">${esc(t)} <b>${avg}%</b></span>`;
}).join("") || `<span class="tierchip">no rated items yet</span>`;
document.getElementById("rows").innerHTML =
  "<tr><th>Item</th><th>Tier</th><th>Rate</th><th>n</th></tr>" +
  DATA.items.map(i => {
    const rate = i.status === "pending" ? "pending" : i.status === "error" ? "error" : (i.rate == null ? "—" : i.rate + "%");
    const n = i.applied == null ? "" : i.complied + " / " + i.applied;
    const bar = typeof i.rate === "number" ? `<div class="meter"><i style="width:${i.rate}%"></i></div>` : "";
    return `<tr class="${i.status === "pending" ? "pending" : ""}">
      <td><code>${esc(i.id)}</code><br>${esc(i.label)}${bar}</td>
      <td><span class="badge">${esc(i.tier)}</span></td>
      <td>${esc(rate)}</td><td>${esc(n)}</td></tr>`;
  }).join("");
const s = DATA.series, W = 320, H = 40;
if (s.length) {
  const max = Math.max(...s, 100), min = Math.min(...s, 0);
  const pts = s.map((v,i) => `${(i/(Math.max(1,s.length-1)))*W},${H-((v-min)/Math.max(1,max-min))*H}`).join(" ");
  document.getElementById("spark").innerHTML = `<polyline fill="none" stroke="#7a5c2e" stroke-width="2" points="${pts}"/>`;
}
</script>
"""


def main():
    from datetime import datetime, timezone
    here = os.path.dirname(os.path.abspath(__file__))
    rubric = json.load(open(os.path.join(here, "pulse-rubric.json"), encoding="utf-8"))
    now = datetime.now(timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    pulse_dir = os.environ.get("PULSE_DIR", os.path.expanduser("~/.skadi/pulse"))
    board_dir = os.environ.get("BOARD_DIR", os.path.expanduser("~/.skadi/board"))
    henneth_dir = os.environ.get("HENNETH_DIR", os.path.expanduser("~/.claude/previews/henneth"))
    files = session_files(_default_roots(), WINDOW_DAYS, now.timestamp())
    items = apply_rubric(files, rubric)
    door = render_dashboard(items, pulse_dir, henneth_dir, now_iso)
    write_outputs(items, pulse_dir, board_dir, now_iso, WINDOW_DAYS, door)
    overall = _overall(items)
    print("adherence pulse: overall %s%% across %d sessions" %
          (overall if overall is not None else "—", len(files)))


if __name__ == "__main__":
    main()
