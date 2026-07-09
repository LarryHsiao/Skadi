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
            while j < n and turns[j]["type"] != "user":
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
    """applied = genuine user prompts; complied = those drawing no grammar note."""
    marker = re.compile(entry["complied"])
    applied = 0
    complied = 0
    for i, turn in enumerate(turns):
        if turn["type"] != "user":
            continue
        text = turn["text"]
        if not text or "<command-name>" in text:
            continue  # empty (tool_result) or a slash invocation — not a prompt
        applied += 1
        nxt = turns[i + 1] if i + 1 < len(turns) else None
        if not (nxt and nxt["type"] == "assistant" and marker.search(nxt["text"])):
            complied += 1
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
        "headline": {"overall": overall, "delta": delta},
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


def render_dashboard(items, pulse_dir, henneth_dir, now_iso):
    return None  # replaced in Task 6


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
