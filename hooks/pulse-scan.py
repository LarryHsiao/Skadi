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
import shutil
import subprocess
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


def _tool_names(message):
    """The tools an assistant turn invoked (Edit, Write, Bash, ...) — dropped by
    _turn_text, which only keeps prose. Needed to tell a free-form edit apart
    from a free-form Q&A the same run-boundary logic would otherwise conflate."""
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [
        b.get("name")
        for b in content
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name")
    ]


def _bash_commands(message):
    """The shell command text of any Bash tool_use blocks in an assistant turn.
    The tool name 'Bash' alone doesn't say whether it mutated anything (git
    status vs. git commit), so the command text is what _mutates actually
    judges."""
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [
        b.get("input", {}).get("command", "")
        for b in content
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"
    ]


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
            message = d.get("message", {})
            turns.append({
                "type": t,
                "text": _turn_text(message),
                "tools": _tool_names(message) if t == "assistant" else [],
                "bash_commands": _bash_commands(message) if t == "assistant" else [],
                "model": message.get("model") if t == "assistant" else None,
                "ts": d.get("timestamp", ""),
            })
    return turns


_SWEEP_MARKER_RE = re.compile(r"<command-name>/(loop|amon-sul)</command-name>")


def _is_sweep_session(turns):
    """A session is sweep-driven if /loop or /amon-sul appears anywhere in it —
    both re-fire a rider (e.g. /aule) on a cadence, and each fire renders as a
    plain <command-name>/aule</command-name> turn indistinguishable from the
    user typing it by hand. Session-level, not per-run: a human's genuinely
    hand-typed command inside a session that also hosts a loop is mis-bucketed
    as sweep too — a known, accepted imprecision, not a per-run classifier."""
    return any(
        turn["type"] == "user" and _SWEEP_MARKER_RE.search(turn["text"])
        for turn in turns
    )


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
             "<local-command-caveat>", "<task-notification>")
    return not any(tok in text for tok in noise)


def _ends_run(turn):
    """A run ends at a genuine user prompt or a new command invocation."""
    return turn["type"] == "user" and (
        _is_prompt(turn["text"]) or "<command-name>" in turn["text"])


def _run_span(turns, i):
    """The turns belonging to the run opened by turns[i], as [i+1, j) — used by
    every scorer that walks 'what happened after this user turn, until the next
    one'."""
    j = i + 1
    n = len(turns)
    while j < n and not _ends_run(turns[j]):
        j += 1
    return j


def _run_model(run):
    """The model that authored this run — the first real (non-synthetic) model
    named on an assistant turn in the run, or None if none is attributable."""
    for turn in run:
        model = turn.get("model")
        if model and model != "<synthetic>":
            return model
    return None


def _bump_model(by_model, model, complied):
    """Tally one applied (and maybe complied) instance against its model."""
    if model is None:
        return
    bucket = by_model.setdefault(model, {"applied": 0, "complied": 0})
    bucket["applied"] += 1
    if complied:
        bucket["complied"] += 1


def score_workflow(turns, entry):
    """applied = invocations; complied = runs where the verdict token appears.
    by_model tallies the same applied/complied split against each run's model."""
    applies = re.compile(entry["applies"])
    complied_re = re.compile(entry["complied"])
    applied = 0
    complied = 0
    by_model = {}
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and applies.search(turn["text"]):
            applied += 1
            j = _run_span(turns, i)
            run = turns[i + 1:j]
            run_text = "\n".join(t["text"] for t in run if t["type"] == "assistant")
            ok = bool(complied_re.search(run_text))
            if ok:
                complied += 1
            _bump_model(by_model, _run_model(run), ok)
            i = j
            continue
        i += 1
    return applied, complied, by_model


def score_grammar(turns, entry):
    """applied = genuine user prompts; complied = those whose run drew no grammar note.
    by_model tallies the same applied/complied split against each run's model."""
    marker = re.compile(entry["complied"])
    applied = 0
    complied = 0
    by_model = {}
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and _is_prompt(turn["text"]):
            applied += 1
            j = _run_span(turns, i)
            run = turns[i + 1:j]
            run_text = "\n".join(t["text"] for t in run if t["type"] == "assistant")
            ok = not marker.search(run_text)
            if ok:
                complied += 1
            _bump_model(by_model, _run_model(run), ok)
            i = j
            continue
        i += 1
    return applied, complied, by_model


_MUTATING_BASH_RE = re.compile(
    r"\bgit\s+(commit|push|add|merge|rebase|reset|clean|checkout\s+-b)\b"
    r"|\b(rm|mkdir|mv|cp|touch|chmod|chown)\s"
    r"|\bsed\s+-i\b"
    r"|\b(npm|pnpm|yarn)\s+(install|uninstall|update|add|remove)\b"
    r"|\bpip\s+install\b"
    r"|\binstall\.sh\b"
    r"|>>?\s+(?!/dev/null\b)(?!nul\b)|\btee\s"
)


def _mutates(turn):
    """An assistant turn that took a tree-changing action — the signal a
    free-form Change Approval gate is judged against. Edit/Write are always
    mutating; a Bash call only counts if its command matches a known write
    verb, so a read (git status, cat, ls) doesn't false-positive."""
    if turn["type"] != "assistant":
        return False
    if any(name in ("Edit", "Write") for name in turn.get("tools", [])):
        return True
    return any(_MUTATING_BASH_RE.search(cmd) for cmd in turn.get("bash_commands", []))


def _gate_complies(gate, complied_re, pre_text):
    """Whether a run's pre-edit narration satisfies this gate's marker."""
    if gate == "approval":
        return bool(pre_text.strip())
    return bool(complied_re and complied_re.search(pre_text))


def score_freeform_gate(turns, entry):
    """applied = free-form runs that took a mutating action with no skill frame
    (the case CLAUDE.md's Task Sizing / Acceptance / Change Approval sections
    bind); complied depends on entry['gate']:
      - 'sizing' / 'acceptance': the marker text appears in the assistant prose
        BEFORE the first mutating turn in the run.
      - 'approval': some narration preceded the first mutating turn at all —
        the run didn't jump straight to editing with no summary first.
    Known limitation: _MUTATING_BASH_RE is a fixed verb list, not a full shell
    parse — an unlisted mutating command (a custom deploy script, a raw curl
    -X POST with a side effect) still won't be caught."""
    complied_re = re.compile(entry["complied"]) if entry.get("complied") else None
    gate = entry.get("gate")
    applied = 0
    complied = 0
    by_model = {}
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and _is_prompt(turn["text"]):
            j = _run_span(turns, i)
            run = turns[i + 1:j]
            mutating_idx = next((k for k, t in enumerate(run) if _mutates(t)), None)
            if mutating_idx is not None:
                applied += 1
                pre_text = "\n".join(t["text"] for t in run[:mutating_idx] if t["type"] == "assistant")
                ok = _gate_complies(gate, complied_re, pre_text)
                if ok:
                    complied += 1
                _bump_model(by_model, _run_model(run), ok)
            i = j
            continue
        i += 1
    return applied, complied, by_model


def _prompt_runs(turns, since):
    """Every prompt-opened run as (prompt_text, run_turns, is_mutating),
    skipping runs whose opening prompt predates `since` (the rule's birth
    date — before it the rule did not exist, so the run could not have
    complied, and billing it only drowns the signal in dead history). Empty
    `since` bills every run. prompt_text is the opening user prompt, kept so
    the task-shot scorer can read its tone."""
    runs = []
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and _is_prompt(turn["text"]):
            j = _run_span(turns, i)
            if turn["ts"][:10] >= since:
                run = turns[i + 1:j]
                runs.append((turn["text"], run, any(_mutates(t) for t in run)))
            i = j
            continue
        i += 1
    return runs


def _task_segments(runs):
    """Runs folded into task segments, each a list of (prompt_text, run_turns,
    is_mutating) triples so callers can still see run boundaries and opening
    prompts (flatten with _segment_turns when only the turn stream matters).
    A task unfolds over many prompt turns — the user steering ("no, the arrow
    points left") between edits — so: a segment opens at a mutating run, carries the
    following mutating streak, and keeps the read-only runs after it as its
    wind-down tail; the next mutating run after that tail opens a new
    segment. Known trade-off: two tasks back-to-back with no read-only run
    between them merge into one segment — slight under-billing, preferred
    over the per-turn over-billing it replaces."""
    segments = []
    seg = None
    in_tail = False
    for prompt, run, is_mutating in runs:
        if is_mutating:
            if seg is None or in_tail:
                if seg is not None:
                    segments.append(seg)
                seg = [(prompt, run, is_mutating)]
                in_tail = False
            else:
                seg.append((prompt, run, is_mutating))
        elif seg is not None:
            seg.append((prompt, run, is_mutating))
            in_tail = True
    if seg is not None:
        segments.append(seg)
    return segments


def _segment_turns(seg):
    """A segment's runs flattened into one ordered turn stream."""
    return [t for _, run, _ in seg for t in run]


def _segment_complies(seg, complied_re):
    """A segment complies when the verdict marker appears after its last
    mutating turn AND an Agent tool_use turn stands at or before the marker
    turn — the marker alone isn't proof a review happened; a model could type
    the closing line unearned. The Agent lookup spans the whole segment, not
    just the post-mutation tail: CLAUDE.md's order is review, then fix the
    findings (more mutating turns), then verify, then the verdict — so the
    Agent call routinely precedes the segment's last edit."""
    mutating_indices = [k for k, t in enumerate(seg) if _mutates(t)]
    if not mutating_indices:
        return False
    post = seg[mutating_indices[-1] + 1:]
    marker_offset = next(
        (k for k, t in enumerate(post)
         if t["type"] == "assistant" and complied_re.search(t["text"])), None)
    if marker_offset is None:
        return False
    marker_idx = mutating_indices[-1] + 1 + marker_offset
    return any(t["type"] == "assistant" and "Agent" in t.get("tools", [])
               for t in seg[:marker_idx + 1])


def score_post_gate(turns, entry):
    """Like score_freeform_gate, but for gates (Compliance Review) that close
    a task rather than open it. applied = task segments (see _task_segments);
    complied = segments whose close carries both the verdict marker and Agent
    delegation evidence (see _segment_complies). entry['since'] (optional,
    ISO date) drops runs from before the rule existed (see _prompt_runs)."""
    complied_re = re.compile(entry["complied"])
    applied = 0
    complied = 0
    by_model = {}
    for seg in _task_segments(_prompt_runs(turns, entry.get("since", ""))):
        seg_turns = _segment_turns(seg)
        applied += 1
        ok = _segment_complies(seg_turns, complied_re)
        if ok:
            complied += 1
        _bump_model(by_model, _run_model(seg_turns), ok)
    return applied, complied, by_model


def score_task_shot(turns, entry):
    """applied = task segments; complied = segments whose rework count stays
    within entry['threshold']. A rework run is a mutating run after the
    segment's first whose opening prompt reads as a correction
    (entry['rework'] regex — "no, the arrow points left"), as opposed to an
    additive follow-up ("also commit and push"), which is progress, not a
    miss. Measures the model's first-shot success, not a config rule — so no
    'since' gate by default, and the byModel split is the headline cut. The
    tone regex is a keyword heuristic; mixed-language prompts can slip it."""
    rework_re = re.compile(entry["rework"])
    threshold = entry.get("threshold", 0)
    applied = 0
    complied = 0
    by_model = {}
    for seg in _task_segments(_prompt_runs(turns, entry.get("since", ""))):
        applied += 1
        reworks = sum(1 for prompt, _, is_mutating in seg[1:]
                      if is_mutating and rework_re.search(prompt))
        ok = reworks <= threshold
        if ok:
            complied += 1
        _bump_model(by_model, _run_model(_segment_turns(seg)), ok)
    return applied, complied, by_model


def _rate(applied, complied):
    return round(100 * complied / applied) if applied else None


def _rated_by_model(by_model):
    """{model: {applied, complied}} → the same, each bucket carrying its rate."""
    return {m: {**c, "rate": _rate(c["applied"], c["complied"])} for m, c in by_model.items()}


def _merge_by_model(total, addition):
    for model, counts in addition.items():
        bucket = total.setdefault(model, {"applied": 0, "complied": 0})
        bucket["applied"] += counts["applied"]
        bucket["complied"] += counts["complied"]


def _all_models(sessions):
    """Every real (non-synthetic) model seen authoring an assistant turn across
    the scanned window — the chip roster, independent of whether a given model
    ever triggered a rubric-applicable run."""
    models = set()
    for turns in sessions:
        for turn in turns:
            model = turn.get("model")
            if model and model != "<synthetic>":
                models.add(model)
    return sorted(models)


def apply_rubric(files, rubric):
    """One result per rubric entry, aggregated across every session file.
    workflow-kind items additionally split into direct (top-level, the
    human running the rider by hand) vs sweep (item["sweep"], a /loop- or
    /amon-sul-fired repeat) — see _is_sweep_session. Every ok item also carries
    byModel (and sweep items carry sweep.byModel), the same split re-cut by
    which model authored the run. Returns (items, models) — models is the full
    chip roster, see _all_models."""
    scorers = {"workflow": score_workflow, "grammar": score_grammar,
               "freeform-gate": score_freeform_gate, "post-gate": score_post_gate,
               "task-shot": score_task_shot}
    sessions = [read_turns(f) for f in files]
    session_is_sweep = [_is_sweep_session(turns) for turns in sessions]
    items = []
    for entry in rubric:
        kind = entry["kind"]
        base = {"id": entry["id"], "label": entry["label"],
                "tier": entry["tier"], "kind": kind,
                "criterion": entry.get("criterion", "")}
        if kind not in scorers:  # git-probe / forge-probe — not built yet
            items.append({**base, "applied": None, "complied": None,
                          "rate": None, "status": "pending"})
            continue
        try:
            applied = complied = 0
            sweep_applied = sweep_complied = 0
            by_model = {}
            sweep_by_model = {}
            for turns, is_sweep in zip(sessions, session_is_sweep):
                a, c, bm = scorers[kind](turns, entry)
                if kind == "workflow" and is_sweep:
                    sweep_applied += a
                    sweep_complied += c
                    _merge_by_model(sweep_by_model, bm)
                else:
                    applied += a
                    complied += c
                    _merge_by_model(by_model, bm)
            item = {**base, "applied": applied, "complied": complied,
                     "rate": _rate(applied, complied), "status": "ok",
                     "byModel": _rated_by_model(by_model)}
            if kind == "workflow":
                item["sweep"] = {"applied": sweep_applied, "complied": sweep_complied,
                                  "rate": _rate(sweep_applied, sweep_complied),
                                  "byModel": _rated_by_model(sweep_by_model)}
            items.append(item)
        except re.error as err:
            print("pulse-scan: %s matcher error: %s" % (entry["id"], err), file=sys.stderr)
            items.append({**base, "applied": None, "complied": None,
                          "rate": None, "status": "error"})
    return items, _all_models(sessions)


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


def _history_series(pulse_dir):
    """Every prior run as {ts, overall, items}, in file order — items rides along
    so the trend can be re-cut by tab/model on the client, not just redraw the
    one cross-tier number every run was reduced to at the time."""
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
                if isinstance(rec.get("overall"), (int, float)) and rec.get("ts"):
                    series.append({"ts": rec["ts"], "overall": rec["overall"],
                                    "items": rec.get("items", [])})
    return series


def render_dashboard(items, models, pulse_dir, henneth_dir, now_iso):
    """A self-contained Henneth page with the scorecard + trend inlined."""
    series = _history_series(pulse_dir)
    overall = _overall(items)
    if isinstance(overall, (int, float)):
        series = series + [{"ts": now_iso, "overall": overall, "items": items}]
    data = json.dumps({"items": items, "series": series, "ts": now_iso, "models": models})
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
  .trendlabel{font-size:.7rem;color:#87795e;margin-top:.6rem;}
  table{border-collapse:collapse;width:100%;margin-top:.6rem;font-size:.85rem;}
  th,td{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #cbb89a;}
  th{font-size:.7rem;text-transform:uppercase;letter-spacing:.04em;color:#87795e;}
  tbody tr:nth-child(even){background:rgba(203,184,154,.12);}
  .tiergroup td{padding-top:.9rem;font-size:.68rem;text-transform:uppercase;letter-spacing:.06em;color:#87795e;border-bottom:1px solid #cbb89a;}
  .badge{font-size:.6rem;text-transform:uppercase;border:1px solid #cbb89a;border-radius:999px;padding:.05rem .4rem;}
  .badge.pending,.badge.no-sweep,.badge.no-data{border-color:#a99b7d;} .badge.error{border-color:#a33;color:#a33;}
  .pending{opacity:.5;} .meter{height:6px;background:#e2d6bb;border-radius:999px;overflow:hidden;margin-top:.25rem;}
  .meter i{display:block;height:100%;background:#7a5c2e;}
  .tabs{display:flex;gap:.4rem;margin:.6rem 0 .2rem;}
  .tabbtn{border:1px solid #cbb89a;border-radius:6px;padding:.3rem .8rem;font-size:.8rem;background:none;cursor:pointer;color:inherit;}
  .tabbtn.active{background:#7a5c2e;color:#fff;border-color:#7a5c2e;}
  .tabnote{font-size:.7rem;color:#87795e;margin:.2rem 0 0;}
  .modelchips{display:flex;gap:.35rem;margin:.5rem 0 .2rem;flex-wrap:wrap;}
  .chip{border:1px solid #cbb89a;border-radius:999px;padding:.18rem .7rem;font-size:.72rem;background:none;cursor:pointer;color:inherit;}
  .chip.active{background:#a68a52;color:#fff;border-color:#a68a52;}
  .info{border:1px solid #cbb89a;border-radius:999px;width:1.15rem;height:1.15rem;line-height:1;font-size:.8rem;padding:0;background:none;cursor:pointer;color:#87795e;vertical-align:middle;}
  .info:hover{border-color:#7a5c2e;color:#7a5c2e;} .info.active{background:#7a5c2e;color:#fff;border-color:#7a5c2e;}
  .critrow{display:none;} .critrow.open{display:table-row;}
  .critrow td{background:rgba(203,184,154,.18);border-bottom:1px solid #cbb89a;}
  .crit{font-size:.78rem;line-height:1.5;color:#5c5138;padding:.15rem .1rem;}
  .crit .ok{color:#3f7a3f;font-weight:700;} .crit .no{color:#a33;font-weight:700;}
</style>
<h1>Adherence Pulse</h1>
<div class="tabs" id="tabs">
  <button class="tabbtn active" data-tab="direct">Direct</button>
  <button class="tabbtn" data-tab="sweep">Sweep</button>
</div>
<div class="modelchips" id="modelchips"></div>
<div class="tabnote" id="tabnote"></div>
<div class="tiers" id="tiers"></div>
<div class="kpi" id="overall">—</div>
<div class="avglabel">cross-tier average</div>
<div class="trendlabel" id="trendlabel">trend, by run date</div>
<svg id="spark" width="320" height="60"></svg>
<table>
  <thead><tr><th>Item</th><th>Rate</th><th>n</th></tr></thead>
  <tbody id="rows"></tbody>
</table>
<script>
const DATA = /*DATA*/;
const esc = (s) => String(s == null ? "" : s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const criterionHtml = (s) => esc(s)
  .replace(/✓/g, '<span class="ok">✓</span>')
  .replace(/✗/g, '<span class="no">✗</span>');
const TIER_ORDER = ["heuristic", "structural", "deterministic"];
const tierRank = (t) => { const i = TIER_ORDER.indexOf(t); return i === -1 ? TIER_ORDER.length : i; };

const TAB_NOTES = {
  direct: "workflow rows count sessions with no /loop or /amon-sul in them — a hand-typed command inside such a session is still counted as sweep.",
  sweep: "workflow rows only — grammar and free-form gate rows carry no sweep concept, so they're dropped from this tab.",
};
const MODEL_LABELS = {
  "claude-opus-4-8": "Opus 4.8",
  "claude-sonnet-5": "Sonnet 5",
  "claude-fable-5": "Fable 5",
};
const modelLabel = (m) => MODEL_LABELS[m] || m;

function viewFor(items, tab) {
  if (tab !== "sweep") return items;
  return items.filter(i => i.kind === "workflow").map(i => {
    if (i.status !== "ok") return i;
    const sw = i.sweep || { applied: 0, complied: 0, rate: null, byModel: {} };
    return { ...i, rate: sw.rate, applied: sw.applied, complied: sw.complied,
             byModel: sw.byModel || {}, status: sw.applied ? "ok" : "no-sweep" };
  });
}

function applyModel(items, model) {
  if (model === "Overall") return items;
  return items.map(i => {
    if (i.status !== "ok") return i;
    const bm = (i.byModel || {})[model];
    if (!bm) return { ...i, rate: null, applied: 0, complied: 0, status: "no-data" };
    return { ...i, rate: bm.rate, applied: bm.applied, complied: bm.complied };
  });
}

function overallFor(items, tab, model) {
  const viewed = applyModel(viewFor(items, tab), model);
  const rated = viewed.filter(i => typeof i.rate === "number");
  return rated.length ? Math.round(rated.reduce((a,i)=>a+i.rate,0)/rated.length) : null;
}

function renderTrend(tab, model) {
  const spark = document.getElementById("spark");
  const pts = (DATA.series || [])
    .map(p => ({ ts: p.ts, overall: overallFor(p.items || [], tab, model) }))
    .filter(p => typeof p.overall === "number");
  const W = 320, H = 60, PAD = 14;
  if (!pts.length) { spark.innerHTML = ""; return; }
  const times = pts.map(p => Date.parse(p.ts));
  const vals = pts.map(p => p.overall);
  const tMin = Math.min(...times), tMax = Math.max(...times);
  const vMax = Math.max(...vals, 100), vMin = Math.min(...vals, 0);
  const x = (t) => times.length > 1 ? ((t - tMin) / Math.max(1, tMax - tMin)) * W : W / 2;
  const y = (v) => (H - PAD) - ((v - vMin) / Math.max(1, vMax - vMin)) * (H - PAD);
  const linePts = times.map((t, i) => `${x(t)},${y(vals[i])}`).join(" ");
  const fmt = (t) => new Date(t).toISOString().slice(0, 10);
  const dots = times.map((t, i) =>
    `<circle cx="${x(t)}" cy="${y(vals[i])}" r="2.5" fill="#7a5c2e"><title>${esc(pts[i].ts)} — ${esc(vals[i])}%</title></circle>`
  ).join("");
  spark.innerHTML =
    `<polyline fill="none" stroke="#7a5c2e" stroke-width="2" points="${linePts}"/>${dots}` +
    `<text x="0" y="${H}" font-size="9" fill="#87795e">${esc(fmt(tMin))}</text>` +
    `<text x="${W}" y="${H}" font-size="9" text-anchor="end" fill="#87795e">${esc(fmt(tMax))}</text>`;
}

let currentTab = "direct";
let currentModel = "Overall";

function render(tab, model) {
  currentTab = tab;
  currentModel = model;
  const modelNote = model === "Overall" ? "" : ` · showing only ${modelLabel(model)}'s runs, recomputed independently.`;
  document.getElementById("tabnote").textContent = TAB_NOTES[tab] + modelNote;
  document.getElementById("modelchips").innerHTML = ["Overall", ...DATA.models].map(m =>
    `<button class="chip ${m === model ? "active" : ""}" data-model="${esc(m)}">${esc(modelLabel(m))}</button>`
  ).join("");
  const items = applyModel(viewFor(DATA.items, tab), model);
  const rated = items.filter(i => typeof i.rate === "number");
  const overall = rated.length ? Math.round(rated.reduce((a,i)=>a+i.rate,0)/rated.length) : null;
  document.getElementById("overall").textContent = overall == null ? "—" : overall + "%";
  document.getElementById("trendlabel").textContent =
    `trend, by run date · ${tab === "sweep" ? "Sweep" : "Direct"} · ${model === "Overall" ? "Overall" : modelLabel(model)}`;
  renderTrend(tab, model);
  const byTier = {};
  rated.forEach(i => { (byTier[i.tier] = byTier[i.tier] || []).push(i.rate); });
  document.getElementById("tiers").innerHTML = Object.keys(byTier).sort().map(t => {
    const avg = Math.round(byTier[t].reduce((a,v)=>a+v,0)/byTier[t].length);
    return `<span class="tierchip">${esc(t)} <b>${avg}%</b></span>`;
  }).join("") || `<span class="tierchip">no rated items yet</span>`;

  const groups = {};
  items.forEach(i => { (groups[i.tier] = groups[i.tier] || []).push(i); });
  const rowHtml = (i) => {
    const rate = i.status === "pending" ? "pending" : i.status === "error" ? "error"
      : i.status === "no-sweep" ? "no sweep data" : i.status === "no-data" ? "no data"
      : (i.rate == null ? "—" : i.rate + "%");
    const n = i.applied == null ? "" : i.complied + " / " + i.applied;
    const bar = typeof i.rate === "number" ? `<div class="meter"><i style="width:${i.rate}%"></i></div>` : "";
    const statusBadge = i.status !== "ok" ? `<span class="badge ${esc(i.status)}">${esc(i.status)}</span>` : "";
    const info = i.criterion ? `<button class="info" data-info="${esc(i.id)}" title="What counts as success / failure">&#9432;</button>` : "";
    const critRow = i.criterion ? `<tr class="critrow" data-crit="${esc(i.id)}"><td colspan="3"><div class="crit">${criterionHtml(i.criterion)}</div></td></tr>` : "";
    return `<tr class="${i.status !== "ok" ? "pending" : ""}">
      <td><code>${esc(i.id)}</code> ${info} ${statusBadge}<br>${esc(i.label)}${bar}</td>
      <td>${esc(rate)}</td><td>${esc(n)}</td></tr>${critRow}`;
  };
  document.getElementById("rows").innerHTML = Object.keys(groups).sort((a, b) => tierRank(a) - tierRank(b)).map(t =>
    `<tr class="tiergroup"><td colspan="3">${esc(t)}</td></tr>` + groups[t].map(rowHtml).join("")
  ).join("");
}

document.querySelectorAll(".tabbtn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tabbtn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    render(btn.dataset.tab, currentModel);
  });
});
document.getElementById("modelchips").addEventListener("click", (e) => {
  const btn = e.target.closest(".chip");
  if (!btn) return;
  render(currentTab, btn.dataset.model);
});
document.getElementById("rows").addEventListener("click", (e) => {
  const btn = e.target.closest(".info");
  if (!btn) return;
  const row = document.querySelector(`.critrow[data-crit="${CSS.escape(btn.dataset.info)}"]`);
  if (!row) return;
  const open = row.classList.toggle("open");
  btn.classList.toggle("active", open);
});
render("direct", "Overall");
</script>
"""


def _regenerate_board_manifest(board_dir):
    """Mirror the sibling channel writers — regenerate the board manifest so the
    pulse tile is discovered. Best-effort; a missing manifest script is not fatal."""
    here = os.path.dirname(os.path.abspath(__file__))
    manifest = os.path.join(here, "board-manifest.py")
    if not os.path.exists(manifest):
        return
    try:
        subprocess.run([sys.executable, manifest, board_dir],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        pass


def _copy_dashboard_to_board(henneth_dir, board_dir):
    """Copy the rendered dashboard into the board dir so the tile's Enter link
    resolves — the board server serves the board dir, not the Henneth dir. Mirrors
    board-growth.sh. Returns the board-relative door, or None if the copy fails."""
    src = os.path.join(henneth_dir, "adherence-pulse.html")
    dst = os.path.join(board_dir, "pulse.html")
    try:
        os.makedirs(board_dir, exist_ok=True)
        shutil.copyfile(src, dst)
        return "pulse.html"
    except OSError as err:
        print("pulse-scan: cannot copy dashboard to board: %s" % err, file=sys.stderr)
        return None


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
    items, models = apply_rubric(files, rubric)
    door = render_dashboard(items, models, pulse_dir, henneth_dir, now_iso)
    board_door = _copy_dashboard_to_board(henneth_dir, board_dir) if door else None
    write_outputs(items, pulse_dir, board_dir, now_iso, WINDOW_DAYS, board_door)
    _regenerate_board_manifest(board_dir)
    overall = _overall(items)
    print("adherence pulse: overall %s%% across %d sessions" %
          (overall if overall is not None else "—", len(files)))


if __name__ == "__main__":
    main()
