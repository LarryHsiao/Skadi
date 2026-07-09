# Adherence Pulse (`/estë`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standing, marker-based health pulse over how faithfully the skadi config's rules and skills are followed across all config roots, rendered as a per-item scorecard with confidence tiers plus a trend.

**Architecture:** A Python engine (`pulse-scan.py`) walks every config root's `projects/**/*.jsonl` read-only, applies a declarative matcher table (`pulse-rubric.json`), and writes a per-run history line, a board-channel snapshot, and a self-contained Henneth dashboard. A thin `estë` skill runs the engine and surfaces the URL; a board tile mirrors the headline. Mirrors the existing growth/board separation of engine, data, and page.

**Tech Stack:** Python 3 (stdlib only — `json`, `glob`, `re`, `os`), bash test harness (mirrors `board-*.test.sh`), self-contained HTML with inlined data (mirrors the Henneth `appgrowth` render).

## Global Constraints

- Read-only: never write to a tracker or a repo; only read `*.jsonl` transcripts. (from spec §Non-goals)
- Markers only in the first cut — no LLM/semantic grading. (spec §What it measures)
- Honest tiers: every scorecard item carries `tier` ∈ `deterministic | structural`; never blend into one number. (spec §Purpose)
- Transcript scope: all of `~/.claude`, `~/.claude-personal`, `~/.claude-work` under `projects/**/*.jsonl`. (spec §Transcript scope)
- Window default: last **30 days**, overridable. (spec §Data flow)
- Python: stdlib only, no third-party deps (matches `board-*.py`).
- Tests: name the expected value first, then compare (repo convention).
- `Date.now()`-style stamping stays injectable for testability — the caller passes `now`; the engine defaults to `datetime.utcnow()` only in `main()`. (spec §Data flow)

## File Structure

- Create `hooks/pulse-rubric.json` — the declarative matcher table (data).
- Create `hooks/pulse-scan.py` — the engine: read transcripts, apply rubric, write history + snapshot + dashboard.
- Create `hooks/pulse-scan.test.sh` — offline tests driven by fixture transcript dirs via the `PULSE_ROOTS` seam.
- Create `skills/estë/SKILL.md` — the `/estë` skill that runs the engine and surfaces the URL.
- Modify `hooks/board.sh` — add a `pulse` verb that runs the engine and points the tile.
- Modify `hooks/board-index.html` — render a `channel:"pulse"` tile in the strip.

Storage at runtime (created by the engine, not checked in):
- `~/.skadi/pulse/history.jsonl` — append-only per-run history (the pulse's store).
- `~/.skadi/board/pulse.json` — the board-channel snapshot (so the board manifest discovers it, like `growth.json`).
- `~/.claude/previews/henneth/adherence-pulse.html` — the rendered dashboard (the tile's Enter door).

---

### Task 1: Rubric data + validator

**Files:**
- Create: `hooks/pulse-rubric.json`
- Test: `hooks/pulse-scan.test.sh` (create the harness here; later tasks append cases)

**Interfaces:**
- Produces: `pulse-rubric.json` — a JSON array of entries, each `{id, label, kind, tier, applies, complied, denom}`. `kind` ∈ `workflow | grammar | git-probe | forge-probe`. `tier` ∈ `deterministic | structural`. Later tasks load this array.

- [ ] **Step 1: Write the rubric data file**

`hooks/pulse-rubric.json`:

```json
[
  {"id": "workflow.glorfindel", "label": "Glorfindel completes", "kind": "workflow", "tier": "structural", "applies": "<command-name>/glorfindel</command-name>", "complied": "\\b(STIRRED|QUIET)\\b", "denom": "invocations"},
  {"id": "workflow.aule", "label": "Aulë completes", "kind": "workflow", "tier": "structural", "applies": "<command-name>/aule</command-name>", "complied": "\\b(STIRRED|QUIET)\\b", "denom": "invocations"},
  {"id": "workflow.anduin", "label": "Anduin completes", "kind": "workflow", "tier": "structural", "applies": "<command-name>/anduin</command-name>", "complied": "\\b(STIRRED|QUIET)\\b", "denom": "invocations"},
  {"id": "workflow.council", "label": "Council posts counsel", "kind": "workflow", "tier": "structural", "applies": "<command-name>/council</command-name>", "complied": "\\[COUNSEL\\]", "denom": "invocations"},
  {"id": "workflow.celebrimbor", "label": "Celebrimbor forges", "kind": "workflow", "tier": "structural", "applies": "<command-name>/celebrimbor</command-name>", "complied": "\\[GWAITH\\]", "denom": "invocations"},
  {"id": "workflow.mithrandir", "label": "Mithrandir renders a verdict", "kind": "workflow", "tier": "structural", "applies": "<command-name>/mithrandir</command-name>", "complied": "\\b(Merge|Hold|Refuse)\\b", "denom": "invocations"},
  {"id": "workflow.mandos", "label": "Mandos pronounces", "kind": "workflow", "tier": "structural", "applies": "<command-name>/mandos</command-name>", "complied": "\\b(Covered|Missing|Scope-crept)\\b", "denom": "invocations"},
  {"id": "workflow.board", "label": "Board serves", "kind": "workflow", "tier": "structural", "applies": "<command-name>/board</command-name>", "complied": "http://localhost:", "denom": "invocations"},
  {"id": "rule.grammar", "label": "Grammar clean (no correction)", "kind": "grammar", "tier": "deterministic", "applies": "", "complied": "> \\*\\*Grammar:\\*\\*", "denom": "messages"},
  {"id": "rule.commit-footer", "label": "Commit bears the session footer", "kind": "git-probe", "tier": "deterministic", "applies": "", "complied": "Claude-Session:", "denom": "commits"},
  {"id": "rule.pr-assignee", "label": "PR/MR self-assigned", "kind": "forge-probe", "tier": "deterministic", "applies": "", "complied": "", "denom": "prs"}
]
```

- [ ] **Step 2: Write the failing validator test (create the harness)**

`hooks/pulse-scan.test.sh`:

```bash
#!/bin/bash
# Offline tests for the adherence pulse. Fixture transcript roots are injected
# via PULSE_ROOTS (colon-separated), and output dirs via PULSE_DIR / BOARD_DIR /
# HENNETH_DIR — no live transcripts, no BigQuery, no forge. Run: bash pulse-scan.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/pulse-scan.py"
RUBRIC="$HERE/pulse-rubric.json"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the rubric is well-formed: every entry has the required keys and legal kind/tier ──
expected_rubric="ok"
actual_rubric=$(python3 - "$RUBRIC" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
kinds = {"workflow", "grammar", "git-probe", "forge-probe"}
tiers = {"deterministic", "structural"}
req = {"id", "label", "kind", "tier", "applies", "complied", "denom"}
for r in rows:
    assert req <= set(r), "missing keys in %s" % r.get("id")
    assert r["kind"] in kinds, "bad kind %s" % r["kind"]
    assert r["tier"] in tiers, "bad tier %s" % r["tier"]
ids = [r["id"] for r in rows]
assert len(ids) == len(set(ids)), "duplicate id"
print("ok")
PY
)
check "rubric is well-formed" "$expected_rubric" "$actual_rubric"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `1 passed, 0 failed` (the rubric file exists and is well-formed).

- [ ] **Step 4: Commit**

```bash
git add hooks/pulse-rubric.json hooks/pulse-scan.test.sh
git commit -m "feat(pulse): declarative rubric + test harness"
```

---

### Task 2: Transcript reader — turn extraction + windowing

**Files:**
- Create: `hooks/pulse-scan.py`
- Test: `hooks/pulse-scan.test.sh` (append)

**Interfaces:**
- Produces:
  - `read_turns(path) -> list[dict]` — ordered turns, each `{"type": str, "text": str, "ts": str}`. `type` ∈ `user | assistant | other`. `text` is the concatenated text of the turn (user string content, or assistant text blocks joined). Torn lines are skipped.
  - `session_files(roots, window_days, now_epoch) -> list[str]` — every `*.jsonl` under `<root>/projects/*/` across roots whose mtime is within `window_days` of `now_epoch`. A missing root is skipped.

- [ ] **Step 1: Write the failing test**

Append to `hooks/pulse-scan.test.sh` before the final `echo`:

```bash
# ── 2 · read_turns extracts ordered user/assistant text; torn lines are skipped ──
d=$(tmpdir)
cat >"$d/t.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"role":"user","content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Glorfindel — STIRRED, 3 planned."}]}}
{ this is a torn line
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"role":"user","content":"thanks"}}
JSON
expected_turns="user:<command-name>/glorfindel</command-name>|assistant:Glorfindel — STIRRED, 3 planned.|user:thanks"
actual_turns=$(python3 -c "
import sys; sys.argv=['x']
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/t.jsonl')
print('|'.join('%s:%s'%(t['type'],t['text']) for t in turns))
")
check "read_turns extracts turns, skips torn line" "$expected_turns" "$actual_turns"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash hooks/pulse-scan.test.sh`
Expected: FAIL — `pulse-scan.py` does not yet exist / `read_turns` undefined.

- [ ] **Step 3: Write the minimal implementation**

`hooks/pulse-scan.py` (start the file):

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add hooks/pulse-scan.py hooks/pulse-scan.test.sh
git commit -m "feat(pulse): transcript reader + windowing"
```

---

### Task 3: Workflow matcher

**Files:**
- Modify: `hooks/pulse-scan.py`
- Test: `hooks/pulse-scan.test.sh` (append)

**Interfaces:**
- Produces: `score_workflow(turns, entry) -> (applied, complied)` — `applied` counts user turns matching `entry["applies"]`; for each, `complied` increments when `entry["complied"]` matches anywhere in the assistant turns of that run (from just after the invocation until the next user turn).

- [ ] **Step 1: Write the failing test**

Append before the final `echo`:

```bash
# ── 3 · workflow matcher: invoked+completed → 1/1; invoked+incomplete → 0/1 ──
d=$(tmpdir)
cat >"$d/done.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — STIRRED, streak 0."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"ok"}}
{"type":"user","timestamp":"2026-07-09T10:02:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:02:05Z","message":{"content":[{"type":"text","text":"working on it, no verdict yet"}]}}
JSON
expected_wf="2/1"
actual_wf=$(python3 -c "
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/done.jsonl')
entry={'applies':'<command-name>/glorfindel</command-name>','complied':r'\b(STIRRED|QUIET)\b'}
a,c=m.score_workflow(turns, entry)
print('%d/%d'%(a,c))
")
check "workflow matcher counts completed runs" "$expected_wf" "$actual_wf"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash hooks/pulse-scan.test.sh`
Expected: FAIL — `score_workflow` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `hooks/pulse-scan.py`:

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add hooks/pulse-scan.py hooks/pulse-scan.test.sh
git commit -m "feat(pulse): workflow completion matcher"
```

---

### Task 4: Grammar matcher

**Files:**
- Modify: `hooks/pulse-scan.py`
- Test: `hooks/pulse-scan.test.sh` (append)

**Interfaces:**
- Produces: `score_grammar(turns, entry) -> (applied, complied)` — `applied` counts genuine user prompts (user turns with non-empty text that are not slash-command invocations); `complied` increments when the immediately following assistant turn does **not** contain the grammar marker `entry["complied"]`.

- [ ] **Step 1: Write the failing test**

Append before the final `echo`:

```bash
# ── 4 · grammar matcher: a clean prompt complies; a corrected one does not ──
d=$(tmpdir)
cat >"$d/g.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"please do the thing"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"can you did it again"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"Sure.\n> **Grammar:** \"did\" → \"do\""}]}}
{"type":"user","timestamp":"2026-07-09T10:02:00Z","message":{"content":"<command-name>/board</command-name>"}}
JSON
expected_g="2/1"
actual_g=$(python3 -c "
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/g.jsonl')
entry={'complied':r'> \*\*Grammar:\*\*'}
a,c=m.score_grammar(turns, entry)
print('%d/%d'%(a,c))
")
check "grammar matcher counts clean prompts" "$expected_g" "$actual_g"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash hooks/pulse-scan.test.sh`
Expected: FAIL — `score_grammar` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `hooks/pulse-scan.py`:

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `4 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add hooks/pulse-scan.py hooks/pulse-scan.test.sh
git commit -m "feat(pulse): grammar-rate matcher"
```

---

### Task 5: Scan orchestration + outputs (history + snapshot)

**Files:**
- Modify: `hooks/pulse-scan.py`
- Test: `hooks/pulse-scan.test.sh` (append)

**Interfaces:**
- Consumes: `read_turns`, `session_files`, `score_workflow`, `score_grammar`.
- Produces:
  - `apply_rubric(files, rubric) -> list[dict]` — one result per rubric entry: `{id, label, tier, kind, applied, complied, rate, status}`. `rate = round(100*complied/applied)` when `applied>0` else `None`. `kind ∈ {git-probe, forge-probe}` → `status="pending"`, `applied=complied=None`. A matcher that raises → `status="error"`; others unaffected.
  - `write_outputs(items, pulse_dir, board_dir, now_iso, window_days, door) -> None` — appends one line to `pulse_dir/history.jsonl` and writes `board_dir/pulse.json` (channel snapshot with `channel:"pulse"`, `headline`, `items`, `delta`, `updated`, `url`). The `delta` is `overall_now − overall_prev`, where `overall` is the mean `rate` of items with a numeric rate, and `prev` comes from the last history line before this run (or `null` on the first run).

- [ ] **Step 1: Write the failing test**

Append before the final `echo`:

```bash
# ── 5 · orchestration: aggregate across sessions; pending items marked; history grows ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir)
mkdir -p "$d/r1/projects/proj-a"
cat >"$d/r1/projects/proj-a/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — QUIET, streak 1."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"good, thanks"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"You are welcome."}]}}
JSON
out=$(PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" 2>/dev/null)
# glorfindel: 1/1 → 100 ; grammar: 1 clean prompt ("good, thanks") → 1/1 → 100 ; commit-footer: pending
expected_orch="100/100/pending"
actual_orch=$(python3 -c "
import json
snap=json.load(open('$board/pulse.json'))
by={i['id']:i for i in snap['items']}
g=by['workflow.glorfindel']['rate']; gr=by['rule.grammar']['rate']; cf=by['rule.commit-footer']['status']
print('%s/%s/%s'%(g,gr,cf))
")
check "orchestration aggregates and marks pending" "$expected_orch" "$actual_orch"

# ── 6 · history append: a second run adds a second line ──
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" >/dev/null 2>&1
expected_hist="2"
actual_hist=$(wc -l < "$pulse/history.jsonl" | tr -d ' ')
check "history grows one line per run" "$expected_hist" "$actual_hist"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash hooks/pulse-scan.test.sh`
Expected: FAIL — `pulse.json` not written (`apply_rubric` / `write_outputs` / `main` missing).

- [ ] **Step 3: Write the minimal implementation**

Append to `hooks/pulse-scan.py`:

```python
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
```

Note: `main()` calls `render_dashboard` (Task 6). Until Task 6 lands, define a temporary stub **above `def main()`** (not at the end of the file — the `if __name__ == "__main__": main()` guard runs at load time, so the stub must be defined before it appears). Place this immediately before `def main()`:

```python
def render_dashboard(items, pulse_dir, henneth_dir, now_iso):
    return None  # replaced in Task 6
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `6 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add hooks/pulse-scan.py hooks/pulse-scan.test.sh
git commit -m "feat(pulse): scan orchestration, history + snapshot outputs"
```

---

### Task 6: Henneth dashboard render

**Files:**
- Modify: `hooks/pulse-scan.py` (replace the `render_dashboard` stub)
- Test: `hooks/pulse-scan.test.sh` (append)

**Interfaces:**
- Produces: `render_dashboard(items, pulse_dir, henneth_dir, now_iso) -> str|None` — writes `henneth_dir/adherence-pulse.html`, a self-contained page with the data inlined, and returns the door filename `"adherence-pulse.html"` (or `None` if `henneth_dir` is unwritable). Reads `pulse_dir/history.jsonl` for the trend.

- [ ] **Step 1: Write the failing test**

Append before the final `echo`:

```bash
# ── 7 · render writes a self-contained dashboard naming each item and its tier ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" python3 "$SCAN" >/dev/null 2>&1
expected_render="yes/yes"
have_file="$([[ -f "$hen/adherence-pulse.html" ]] && echo yes || echo no)"
names_item="$(grep -q 'workflow.glorfindel' "$hen/adherence-pulse.html" && echo yes || echo no)"
actual_render="$have_file/$names_item"
check "dashboard rendered, names the item" "$expected_render" "$actual_render"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash hooks/pulse-scan.test.sh`
Expected: FAIL — the stub returns `None` and writes no file.

- [ ] **Step 3: Write the minimal implementation**

Replace the `render_dashboard` stub in `hooks/pulse-scan.py` with:

```python
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
  table{border-collapse:collapse;width:100%;margin-top:1rem;font-size:.85rem;}
  th,td{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #cbb89a;}
  .badge{font-size:.6rem;text-transform:uppercase;border:1px solid #cbb89a;border-radius:999px;padding:.05rem .4rem;}
  .pending{opacity:.5;} .meter{height:6px;background:#e2d6bb;border-radius:999px;overflow:hidden;}
  .meter i{display:block;height:100%;background:#7a5c2e;}
</style>
<h1>Adherence Pulse</h1>
<div class="kpi" id="overall">—</div>
<svg id="spark" width="320" height="40"></svg>
<table id="rows"></table>
<script>
const DATA = /*DATA*/;
const esc = (s) => String(s == null ? "" : s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const rated = DATA.items.filter(i => typeof i.rate === "number");
const overall = rated.length ? Math.round(rated.reduce((a,i)=>a+i.rate,0)/rated.length) : null;
document.getElementById("overall").textContent = overall == null ? "—" : overall + "%";
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
// sparkline of overall across runs
const s = DATA.series, W = 320, H = 40;
if (s.length) {
  const max = Math.max(...s, 100), min = Math.min(...s, 0);
  const pts = s.map((v,i) => `${(i/(Math.max(1,s.length-1)))*W},${H-((v-min)/Math.max(1,max-min))*H}`).join(" ");
  document.getElementById("spark").innerHTML = `<polyline fill="none" stroke="#7a5c2e" stroke-width="2" points="${pts}"/>`;
}
</script>
"""
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/pulse-scan.test.sh`
Expected: `7 passed, 0 failed`.

- [ ] **Step 5: Manual eye-check (verification that cannot be automated)**

Render against live transcripts and open the page in Henneth:

Run: `python3 hooks/pulse-scan.py && cp previews/henneth/skadi-theme.css ~/.claude/previews/henneth/ 2>/dev/null; echo open ~/.claude/previews/henneth/adherence-pulse.html`
Expected: the page shows an overall %, one row per rubric item with its tier badge, `pending` rows greyed, and a sparkline. Confirm by eye that no row blends tiers and pending rows read "pending", not "0%".

- [ ] **Step 6: Commit**

```bash
git add hooks/pulse-scan.py hooks/pulse-scan.test.sh
git commit -m "feat(pulse): Henneth dashboard render"
```

---

### Task 7: The `estë` skill

**Files:**
- Create: `skills/estë/SKILL.md`

**Interfaces:**
- Consumes: `hooks/pulse-scan.py`, the Henneth server (`/henneth` pattern).
- Produces: the `/estë` user-invocable skill.

- [ ] **Step 1: Write the skill**

`skills/estë/SKILL.md`:

```markdown
---
name: estë
description: Use when the user runs /estë. Computes the adherence pulse — a marker-based, per-item scorecard (with confidence tiers) of how faithfully the skadi config's rules and skills are followed across all config roots — appends the run to history, renders a Henneth dashboard, and prints its URL. Read-only over transcripts; never writes to a tracker or repo. Runs on demand; wrap in /loop or cron for a standing cadence.
user_invocable: true
---

# Estë — The Adherence Pulse

Estë, the Vala of healing and rest, measures the health of the work: how
faithfully the config's rules and skills are kept. One run scans every config
root's transcripts, scores each rubric item, and lays a dashboard in the Henneth
window.

## Run

    python3 ~/.claude/hooks/pulse-scan.py

This walks `~/.claude`, `~/.claude-personal`, `~/.claude-work` under
`projects/**/*.jsonl` (read-only), appends a line to `~/.skadi/pulse/history.jsonl`,
writes the board channel `~/.skadi/board/pulse.json`, and renders
`~/.claude/previews/henneth/adherence-pulse.html`. It prints the headline overall.

Then ensure the Henneth window is up (boot it with `/henneth` if not) and surface
the dashboard URL inline — the page follows the folder, so the pulse appears on its
own once rendered.

## Notes

- **Read-only.** The pulse reads transcripts; it never writes to a tracker or repo.
- **Markers only.** The first cut scores machine-checkable signals — per-skill
  completion and grammar rate. Two rule items (commit-footer, PR assignee) are
  defined but marked `pending` until their git/forge probes are built.
- **Honest tiers.** Each item carries a confidence tier; the page never blends them
  into one number.
- **Standing cadence.** The skill arms nothing. For a recurring pulse, wrap it:
  `/loop 6h /estë`, or a cron.
- **Tests ride beside the hook** — `pulse-scan.test.sh` runs offline via injected
  fixture roots (`PULSE_ROOTS`).
```

- [ ] **Step 2: Verify the skill file parses (frontmatter + name)**

Run: `python3 -c "import re,sys; t=open('skills/estë/SKILL.md',encoding='utf-8').read(); assert t.startswith('---'); assert 'name: estë' in t; assert 'user_invocable: true' in t; print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add "skills/estë/SKILL.md"
git commit -m "feat(pulse): the /estë skill"
```

---

### Task 8: Board tile

**Files:**
- Modify: `hooks/board.sh` (add a `pulse` verb)
- Modify: `hooks/board-index.html` (render the pulse channel in the strip)
- Test: manual eye-check (board render); the manifest already discovers `pulse.json`.

**Interfaces:**
- Consumes: `pulse-scan.py` (writes `pulse.json` into `BOARD_DIR`), the existing `board-manifest.py`.
- Produces: a `pulse` board verb and a strip tile.

- [ ] **Step 1: Add the `pulse` verb to `board.sh`**

In `hooks/board.sh`, add a case beside `growth` (after the `growth)` block, before `remove)`):

```bash
  pulse)
    exec python3 "$DIR/pulse-scan.py" "$@"
    ;;
```

And extend the header comment's passthrough line:

```bash
# Passthroughs to the channel writers: `growth` refreshes the metis growth tile,
# `sweep <name> <verdict> [detail] [scope]` records an amon-sul sweep verdict,
# `pulse` recomputes the adherence pulse channel + dashboard.
```

- [ ] **Step 2: Render the pulse tile in `board-index.html`**

In `renderStrip` (near the growth tile at `board-index.html:425-428`), add a pulse tile. First, in the `poll()` body where `growth` is found (`board-index.html:375`), add:

```javascript
const pulse = channels.find((c) => c.channel === "pulse");
```

Pass `pulse` into `renderStrip(tickets, growth, sweeps, pulse)` and update its signature. Inside `renderStrip`, beside the growth tile, add:

```javascript
pulse && pulse.headline
  ? `<div class="tile"><div class="lbl">Adherence</div>
      <div class="kpi">${pulse.headline.overall == null ? "—" : pulse.headline.overall + "%"}<small> pulse</small></div>
      ${pulse.url ? `<a class="enter" href="${esc(pulse.url)}" target="_blank" rel="noopener" style="font-size:0.7rem">Enter ↵</a>` : ""}</div>`
  : ""
```

(Match the exact markup style of the adjacent growth tile; the formatter will re-wrap.)

- [ ] **Step 3: Verify the channel joins the manifest**

Run:
```bash
d=$(mktemp -d); r=$(mktemp -d); mkdir -p "$r/projects/p"
printf '%s\n' '{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/board</command-name>"}}' '{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"http://localhost:1234/"}]}}' > "$r/projects/p/s.jsonl"
PULSE_ROOTS="$r" PULSE_DIR="$(mktemp -d)" BOARD_DIR="$d" HENNETH_DIR="$(mktemp -d)" python3 hooks/pulse-scan.py >/dev/null 2>&1
python3 hooks/board-manifest.py "$d"
jq -e '.channels | index("pulse.json") != null' "$d/channels.json" && echo "in-manifest" || echo "missing"
rm -rf "$d" "$r"
```
Expected: `in-manifest`

- [ ] **Step 4: Manual eye-check (board render)**

Run: `~/.claude/hooks/board.sh serve` then `~/.claude/hooks/board.sh pulse`, open the board URL.
Expected: an "Adherence" tile in the strip showing the overall %, linking (Enter ↵) to the full dashboard.

- [ ] **Step 5: Commit**

```bash
git add hooks/board.sh hooks/board-index.html
git commit -m "feat(pulse): board tile for the adherence pulse"
```

---

## Notes for the implementer

- The engine is stdlib-only Python; run every test with `bash hooks/pulse-scan.test.sh` after each task — it accumulates cases (1 → 7 across Tasks 1–6).
- `skills/estë/` bears a non-ASCII directory name (ë). Quote it in shell commands. If the harness rejects the ë, fall back to `skills/este/` and set `name: este` in the frontmatter — note the change to the user.
- After all tasks: run `/install` to propagate, then `/estë` (or `board.sh pulse`) to compute the first real pulse.
- The two `pending` rubric rows are intentional — they are the seam for the later git/forge-probe slice, not a bug.
