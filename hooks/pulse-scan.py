#!/usr/bin/env python3
"""pulse-scan.py — the adherence pulse engine.

Walks Claude projects/*/*.jsonl and Codex sessions/**/*.jsonl (read-only), applies the
declarative rubric (pulse-rubric.json), and writes a per-run history line, a
board-channel snapshot, and a self-contained Henneth dashboard. Subagent
transcripts, a level deeper, are read only where a session's own reviewers are
wanted (see _review_transcripts) — never scored as sessions in their own right.

Test seams: PULSE_ROOTS (colon-separated fixture roots) overrides the config
roots; PULSE_DIR / BOARD_DIR / HENNETH_DIR override the output folders.
"""
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

WINDOW_DAYS = 30
SECONDS_PER_DAY = 86400

# A gauge the assistant actually rendered: one filled bar followed by its tier
# word. gate-reminder.sh injects the empty template into every user prompt
# ("Size ▰▱▱|▰▰▱|▰▰▰ <minimum|medium|heavy>"), so a naive "Size ▰" match scores
# the hook's own reminder as compliance — 1948 raw matches across the live
# roots, of which only 252 are gates the assistant rendered.
# Known false positive: an assistant turn that quotes a past gauge back — in a
# summary, or reading a spec aloud — reads as a fresh gate. Fenced code blocks
# cannot discriminate, since a real gate is rendered inside fences too. Such a
# gate draws no reply and the judge marks it abandoned, which is excluded from
# the rate, so the cost is a slightly padded abandoned count, not a wrong rate.
GAUGE_RE = re.compile(r"Size (?:▰▱▱|▰▰▱|▰▰▰) +(?:minimum|medium|heavy)")
REMINDER_RE = re.compile(r"Size ▰▱▱\|▰▰▱\|▰▰▰")

# A Compliance Review closing PASS specifically — not PASS|FAIL like
# rule.compliance-review's marker, since bug-gate cares whether the segment
# actually closed clean, not merely whether the ritual was performed. Both
# constants tolerate the full-width colon, as the rubric's own patterns do:
# bug-gate is the one call site that cannot inherit those, so the two must be
# kept in step by hand.
COMPLIANCE_PASS_RE = re.compile(r"Compliance Review[:：]\s*PASS")

# Either verdict a review agent may file. _segment_complies asks two different
# questions of these two patterns: COMPLIANCE_PASS_RE decides what the segment
# closed with, this one decides whether a reviewer reported at all.
COMPLIANCE_VERDICT_RE = re.compile(r"Compliance Review[:：]\s*(PASS|FAIL)")

JUDGE_BATCH = 20
JUDGE_TIMEOUT = 600

# How many assistant turns may stand between a gate and the question that
# answers it. The harness splits prose from tool calls, so the legitimate shape
# is gauge, then one turn carrying the question: 18 of the 19 such gates in the
# live roots sit at exactly that distance, the 19th at four — which is the
# assistant having worked on past its own gate, and should not be credited.
GATE_QUESTION_REACH = 1


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
            if isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text")
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


TOOL_RESULT_KEEP = 240
ANSWERED_MARK = "Your questions have been answered"


def _tool_results(message):
    """The tool results a user turn carries, as {is_error, text}. _turn_text
    keeps prose only, so a turn that is purely a tool result reads as empty —
    but the plan-gate scorer must tell an answered AskUserQuestion from a
    rejected one, and only the result block says which. The text is clipped:
    the marker that decides it stands at the front."""
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    results = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        body = block.get("content")
        text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        results.append({"is_error": bool(block.get("is_error")),
                        "text": text[:TOOL_RESULT_KEEP]})
    return results


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


def _codex_tool(name, raw_input):
    """Translate a Codex tool item to the Claude-shaped names used by scorers."""
    haystack = "%s\n%s" % (name or "", raw_input or "")
    if "apply_patch" in haystack:
        return "Write"
    if re.search(r"(?:spawn_agent|followup_task|send_message|wait_agent)", haystack):
        return "Agent"
    if "request_user_input" in haystack:
        return "AskUserQuestion"
    if name in ("exec", "exec_command", "functions.exec_command") or "exec_command" in haystack:
        return "Bash"
    return name or "CodexTool"


def _codex_tool_input(payload):
    raw = payload.get("arguments", payload.get("input", ""))
    if isinstance(raw, dict):
        return raw, json.dumps(raw, ensure_ascii=False)
    if not isinstance(raw, str):
        raw = json.dumps(raw, ensure_ascii=False)
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        parsed = {"command": raw}
    if not isinstance(parsed, dict):
        parsed = {"command": raw}
    return parsed, raw


def _codex_message(payload):
    return {"content": payload.get("content", [])}


def _codex_tool_result(payload):
    body = payload.get("output", "")
    return {"content": [{"type": "tool_result", "content": body}]}


def read_turns(path):
    """Ordered Claude or Codex turns; torn lines skipped, not fatal. Each
    turn carries the session it came from, so a scorer can key a per-gate cache
    by session and turn index, and the path it was read from, so a scorer can
    reach the session's own subagent transcripts (see _review_transcripts)."""
    session = os.path.splitext(os.path.basename(path))[0]
    turns = []
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError as err:
        print("pulse-scan: cannot open %s: %s" % (path, err), file=sys.stderr)
        return turns
    active_model = None
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue  # torn write — skip, don't blank the session
            runtime = "claude"
            t = d.get("type")
            message = d.get("message", {})
            if t == "turn_context":
                active_model = (d.get("payload") or {}).get("model") or active_model
                continue
            if t == "response_item":
                runtime = "codex"
                payload = d.get("payload") or {}
                item_type = payload.get("type")
                if item_type == "message" and payload.get("role") in ("user", "assistant"):
                    t = payload["role"]
                    message = _codex_message(payload)
                elif item_type in ("function_call", "custom_tool_call"):
                    parsed, raw = _codex_tool_input(payload)
                    name = _codex_tool(payload.get("name"), raw)
                    if name == "Bash" and "command" not in parsed:
                        parsed["command"] = raw
                    t = "assistant"
                    message = {"content": [{"type": "tool_use", "name": name,
                                              "input": parsed}]}
                elif item_type in ("function_call_output", "custom_tool_call_output"):
                    t = "user"
                    message = _codex_tool_result(payload)
                else:
                    continue
            elif t not in ("user", "assistant"):
                continue
            turns.append({
                "type": t,
                "text": _turn_text(message),
                "tools": _tool_names(message) if t == "assistant" else [],
                "bash_commands": _bash_commands(message) if t == "assistant" else [],
                "tool_results": _tool_results(message) if t == "user" else [],
                "model": (message.get("model") or active_model) if t == "assistant" else None,
                "ts": d.get("timestamp", ""),
                "session": session,
                "source": path,
                "runtime": runtime,
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
    """Recent Claude project transcripts and Codex session rollouts."""
    cutoff = now_epoch - window_days * SECONDS_PER_DAY
    found = []
    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        candidates = glob.glob(os.path.join(root, "projects", "*", "*.jsonl"))
        candidates += glob.glob(os.path.join(root, "sessions", "**", "*.jsonl"), recursive=True)
        for path in candidates:
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
             "<local-command-caveat>", "<task-notification>",
             "<environment_context>")
    return not any(tok in text for tok in noise)


def _is_run_boundary(text):
    """A user turn that marks a run boundary: a genuine prompt, or a slash-
    command invocation. Broader than _is_prompt alone — that function treats
    <command-name> as noise so _reply_after/_picked_option correctly skip past
    it when hunting for a gate's genuine reply, but a run *boundary* must also
    open at a skill invocation: without this, any mutating work a skill does
    on its own — with no genuine prompt following it in the transcript — falls
    into the gap between two boundary turns and is never captured by any run,
    hence invisible to every segment-based scorer (score_task_shot,
    score_post_gate, score_bug_gate)."""
    return _is_prompt(text) or "<command-name>" in text


def _reply_after(turns, i):
    """The user's answer to the gate rendered at turns[i] — the next genuine
    prompt, skipping harness injections and the gate reminder that rides on
    every prompt. '' when the gate went unanswered: either the session ended,
    or the user walked away to a slash command, which is abandonment rather
    than a verdict. Scanning past that command would staple a much later,
    unrelated prompt onto this gate as its answer."""
    for turn in turns[i + 1:]:
        if turn["type"] != "user":
            continue
        text = turn["text"]
        if "<command-name>" in text:
            return ""
        if not _is_prompt(text) or REMINDER_RE.search(text):
            continue
        return text.strip()
    return ""


def _picked_option(turns, i):
    """The recorded selection, when the gate at turns[i] offered the user options
    and they picked one; '' otherwise. It becomes that gate's reply, so the judge
    weighs which option was chosen rather than the choice being waved through:
    auto-accepting every picked option pinned a tenth of the denominator at 100%
    by construction, which is no measurement at all.

    The search runs from the gate to the first sign that work has begun: the run's
    end, a mutating turn, a second gauge, or more than GATE_QUESTION_REACH
    assistant turns of narration. The turn boundary alone cannot be the test,
    because the harness records prose and a tool call as separate assistant turns
    — in the live roots every gauge turn carries no tools and the question follows
    on the next. But a question reached only after the assistant kept talking or
    editing is about that work, not about whether this plan was approved, and
    crediting the gate for it would flatter exactly the case this row exists to
    catch. A rejected question is no answer either: the prose reply that follows
    decides that gate instead."""
    narration = 0
    for turn in turns[i + 1:]:
        if _ends_run(turn):
            return ""
        if turn["type"] == "assistant":
            if _mutates(turn) or GAUGE_RE.search(turn["text"]):
                return ""
            narration += 1
            if narration > GATE_QUESTION_REACH:
                return ""
            continue
        for result in turn.get("tool_results", []):
            if not result["is_error"] and ANSWERED_MARK in result["text"]:
                return result["text"].strip()
    return ""


def _gate_sites(turns):
    """Every gate the assistant rendered, as {key, gauge, reply, model, date}.
    One site per assistant turn bearing a filled gauge. `reply` is what answered
    it — the option the user picked, or failing that the next prompt they typed —
    and is what the judge weighs; `date` is the session's own date, so the rate
    can be cut by when the gate happened rather than when the pulse ran."""
    sites = []
    for i, turn in enumerate(turns):
        if turn["type"] != "assistant" or not GAUGE_RE.search(turn["text"]):
            continue
        sites.append({
            "key": "%s:%d" % (turn.get("session", ""), i),
            "gauge": turn["text"].strip(),
            "reply": _picked_option(turns, i) or _reply_after(turns, i),
            "model": _real_model(turn.get("model")),
            "date": (turn.get("ts") or "")[:10],
        })
    return sites


def _ends_run(turn):
    """A run ends at a genuine user prompt or a new command invocation."""
    return turn["type"] == "user" and _is_run_boundary(turn["text"])


def _run_span(turns, i):
    """The turns belonging to the run opened by turns[i], as [i+1, j) — used by
    every scorer that walks 'what happened after this user turn, until the next
    one'."""
    j = i + 1
    n = len(turns)
    while j < n and not _ends_run(turns[j]):
        j += 1
    return j


SYNTHETIC_MODEL = "<synthetic>"


def _real_model(model):
    """A model name fit to tally against, or None. The synthetic sentinel names
    no real author, so it must never become a chip or a chart series."""
    return model if model and model != SYNTHETIC_MODEL else None


def _run_model(run):
    """The model that authored this run — the first real (non-synthetic) model
    named on an assistant turn in the run, or None if none is attributable."""
    for turn in run:
        model = _real_model(turn.get("model"))
        if model:
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
    """Every run opened by a genuine prompt OR a slash-command invocation, as
    (prompt_text, run_turns, is_mutating) — see _is_run_boundary for why a
    command invocation must open a run too: a skill's own mutating work would
    otherwise sit in the gap between two boundary turns and never be
    captured. Skips runs whose opening prompt predates `since` (the rule's
    birth date — before it the rule did not exist, so the run could not have
    complied, and billing it only drowns the signal in dead history). Empty
    `since` bills every run. prompt_text is the opening turn's text, kept so
    the task-shot scorer can read its tone."""
    runs = []
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and _is_run_boundary(turn["text"]):
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


def _segment_complies(seg, complied_re, review_times):
    """A segment complies when the verdict marker appears after its last
    mutating turn AND a Compliance Review agent filed its own verdict within
    the segment, at or before that marker — review_times being when this
    session's reviewers reported (see _review_times).

    Neither half suffices alone. The marker is no proof: a model could type the
    closing line unearned. Nor is a bare Agent tool_use, which this check once
    accepted — an unrelated Explore search satisfies that as readily as a
    review does, and it credited one segment in five whose session had filed no
    verdict at all. Only a reviewer that reported counts.

    The window opens at the segment's start rather than its last edit, because
    CLAUDE.md's order is review, then mend the findings (more mutating turns),
    then verify, then the verdict — so the review routinely precedes the
    segment's last edit.

    The window is compared as ISO-8601 text, which the harness writes in one
    fixed UTC shape. A turn bearing no timestamp therefore falls outside every
    window: no time, no proof."""
    mutating_indices = [k for k, t in enumerate(seg) if _mutates(t)]
    if not mutating_indices:
        return False
    post = seg[mutating_indices[-1] + 1:]
    marker = next((t for t in post
                   if t["type"] == "assistant" and complied_re.search(t["text"])), None)
    if marker is None:
        return False
    start = next((t["ts"] for t in seg if t["ts"]), "")
    return any(start <= ts <= marker["ts"] for ts in review_times)


def _segment_skipped(seg, complied_re, skipped_re, review_times):
    """Whether this segment's Compliance Review was explicitly, reasonedly
    waived rather than silently missed: a SKIPPED marker follows the
    segment's last mutating turn. No review evidence is required here — unlike
    _segment_complies, a skip marker's presence *is* the decision being
    recorded, not a claim that a review happened. A segment that already
    complies outright is never counted as skipped, even if skip-marker text
    also happens to appear somewhere in it — complying takes priority."""
    if _segment_complies(seg, complied_re, review_times):
        return False
    mutating_indices = [k for k, t in enumerate(seg) if _mutates(t)]
    if not mutating_indices:
        return False
    post = seg[mutating_indices[-1] + 1:]
    return any(t["type"] == "assistant" and skipped_re.search(t["text"]) for t in post)


def score_post_gate(turns, entry):
    """Like score_freeform_gate, but for gates (Compliance Review) that close
    a task rather than open it. applied = task segments (see _task_segments)
    minus any explicitly skipped (see _segment_skipped, entry['skipped']);
    complied = segments whose close carries both the verdict marker and a
    review agent's own filed verdict (see _segment_complies). entry['since']
    (optional, ISO date) drops runs from before the rule existed (see
    _prompt_runs). entry['skipped'] is optional — omitting it disables
    skip-detection entirely, identical to behavior before this existed."""
    complied_re = re.compile(entry["complied"])
    skipped_re = re.compile(entry["skipped"]) if entry.get("skipped") else None
    since = entry.get("since", "")
    review_times = _review_times(turns, complied_re, since)
    applied = 0
    complied = 0
    by_model = {}
    for seg in _task_segments(_prompt_runs(turns, since)):
        seg_turns = _segment_turns(seg)
        if skipped_re is not None and _segment_skipped(seg_turns, complied_re,
                                                       skipped_re, review_times):
            continue  # an explicit, reasoned skip is not silence — excluded from both sides
        applied += 1
        ok = _segment_complies(seg_turns, complied_re, review_times)
        if ok:
            complied += 1
        _bump_model(by_model, _run_model(seg_turns), ok)
    return applied, complied, by_model


def _skipped_reviews(sessions, entry):
    """Segments whose Compliance Review was explicitly skipped, counted so the
    row can report them beside the rate rather than hide the exclusion —
    mirrors _abandoned_gates for plan.accepted. Not folded into
    score_post_gate's own count: that function excludes these from
    applied/complied; this counts the population it deliberately leaves out.
    0 when entry carries no 'skipped' pattern."""
    if not entry.get("skipped"):
        return 0
    complied_re = re.compile(entry["complied"])
    skipped_re = re.compile(entry["skipped"])
    since = entry.get("since", "")
    waived = 0
    for turns in sessions:
        review_times = _review_times(turns, complied_re, since)
        for seg in _task_segments(_prompt_runs(turns, since)):
            if _segment_skipped(_segment_turns(seg), complied_re, skipped_re, review_times):
                waived += 1
    return waived


def _review_transcripts(turns):
    """Every subagent transcript this session spawned. The harness writes them
    beside the session file, at <session>/subagents/agent-*.jsonl, so a
    session's reviewers are reachable from the path read_turns recorded on its
    turns. session_files deliberately globs only one level, so these are never
    scored as sessions in their own right — only read from here."""
    if not turns:
        return []
    stem = os.path.splitext(turns[0]["source"])[0]
    return sorted(glob.glob(os.path.join(stem, "subagents", "*.jsonl")))


def _agent_verdict(turns, reviewed_re, since):
    """The Compliance Review verdict a subagent reported, as {'text': the
    matched marker ('Compliance Review: FAIL'), 'ts': when it was filed}, or
    None when this agent was no reviewer — the marker appears on no turn dated
    at or after `since`. The last match wins: a reviewer may quote
    the rule or weigh both outcomes before it settles, and the verdict is what
    it settles on. The timestamp is what lets a segment tell a review of its
    own work from one belonging to a neighbour (see _segment_complies)."""
    verdict = None
    for turn in turns:
        if turn["type"] != "assistant" or turn["ts"][:10] < since:
            continue
        for match in reviewed_re.finditer(turn["text"]):
            verdict = {"text": match.group(0), "ts": turn["ts"]}
    return verdict


def _review_times(turns, reviewed_re, since):
    """When each of this session's Compliance Review agents filed its verdict.
    Computed once per session and handed to every segment check — re-reading
    the subagent transcripts per segment would be quadratic in a long
    session."""
    filed = []
    for path in _review_transcripts(turns):
        verdict = _agent_verdict(read_turns(path), reviewed_re, since)
        if verdict is not None:
            filed.append(verdict["ts"])
    return filed


def _review_fail_items(turns, entry):
    """FAIL reviews located inside a task segment, each as {"key", "findings",
    "context"} for the mend-judge (MEND_JUDGE_PROMPT) to classify "mended" or
    "unmended". Walked separately from score_review_verdict's own pass because
    that pass needs no segment membership and this one does: the judge is
    shown what the segment did after the FAIL, up to its close — a real mend
    shows up there or nowhere.

    key = "<session>:<subagent transcript filename>" — unique per dispatch and
    stable across runs, since a closed transcript never changes; the shape
    _judge_pending's on-disk cache already expects a caller's key to hold.
    findings = the reviewer's own full report (the whole assistant turn
    carrying the marker), not just the matched "Compliance Review: FAIL"
    substring — the judge needs the actual findings to grade against.
    context = the segment's own turns dated after the review, concatenated —
    every edit or explanation that followed, which is where a real mend would
    leave its trace, or where its absence would. A FAIL whose timestamp falls
    inside no segment's span is skipped — there is nothing to show the judge
    followed it."""
    reviewed_re = re.compile(entry["reviewed"])
    passed_re = re.compile(entry["complied"])
    since = entry.get("since", "")
    session = turns[0]["session"] if turns else ""
    segments = [_segment_turns(seg) for seg in _task_segments(_prompt_runs(turns, since))]
    items = []
    for path in _review_transcripts(turns):
        rturns = read_turns(path)
        # _agent_verdict, not a bare passed_re.search over the turn's own text:
        # a reviewer may quote the rule ("close with PASS or FAIL") before it
        # settles on FAIL, and a bare search would match that quoted PASS.
        verdict = _agent_verdict(rturns, reviewed_re, since)
        if verdict is None or passed_re.search(verdict["text"]):
            continue
        ts = verdict["ts"]
        findings_turn = next(t for t in rturns if t["ts"] == ts)
        seg_turns = next((s for s in segments if s and s[0]["ts"] <= ts <= s[-1]["ts"]), None)
        if seg_turns is None:
            continue
        context = "\n".join(t["text"] for t in seg_turns if t["ts"] > ts and t["text"])
        items.append({"key": "%s:%s" % (session, os.path.basename(path)),
                      "findings": findings_turn["text"], "context": context})
    return items


def score_review_verdict(turns, entry):
    """applied = the Compliance Reviews this session actually ran — one per
    subagent transcript whose report carries a verdict (entry['reviewed']);
    complied = those whose FINAL result reads sound: a PASS outright, or a
    FAIL the mend-judge calls "mended" (see _review_fail_items,
    MEND_JUDGE_PROMPT) — a finding raised and then fixed before the segment
    closed is the review doing its job, not a miss against it. A FAIL left
    unjudged (the judge unreachable, or it fell inside no segment to show a
    mend in) stays uncredited here: this row asks whether the work ultimately
    shipped sound, and an unproven mend is not proof of that. review.recovered
    isolates the FAIL population alone and names the recovery rate this row's
    "final result" framing folds in but does not show on its own.

    Read from the reviewer's own transcript, never the thread's closing line,
    because the thread never writes FAIL: CLAUDE.md's order is review, then fix
    the findings, then report — so by the time the closing line is typed the
    findings are mended and it reads PASS. Scoring that line asked the
    summarizer to grade itself, and admitted a segment to the denominator by
    the very marker that scored it, so the rate could only ever read 100%.

    This asks a different question from rule.compliance-review: not whether the
    ritual was performed but, among the reviews that were, how many closed
    clean. A session that ran no review is neither credited nor penalized;
    _unreviewed_segments counts the segments that closed unreviewed so the row
    can name what it left out.

    byModel attributes a review to the model that authored the session under
    review, not the lighter model that reviewed it — the row weighs the work,
    not the reviewer. A session is near enough single-model for its first model
    to stand for the whole; that approximation is part of why the tier reads
    heuristic."""
    reviewed_re = re.compile(entry["reviewed"])
    passed_re = re.compile(entry["complied"])
    since = entry.get("since", "")
    author = _run_model(turns)
    session = turns[0]["session"] if turns else ""
    mend_cache = _mend_verdicts()
    applied = 0
    complied = 0
    by_model = {}
    for path in _review_transcripts(turns):
        verdict = _agent_verdict(read_turns(path), reviewed_re, since)
        if verdict is None:
            continue
        applied += 1
        ok = bool(passed_re.search(verdict["text"]))
        if not ok:
            key = "%s:%s" % (session, os.path.basename(path))
            ok = mend_cache.get(key) == MENDED_VERDICT
        if ok:
            complied += 1
        _bump_model(by_model, author, ok)
    return applied, complied, by_model


def score_review_recovered(turns, entry):
    """applied = FAIL reviews located inside a task segment (see
    _review_fail_items — a FAIL with no segment to show a mend in cannot be
    judged, so it is absent here rather than guessed at); complied = those the
    mend-judge calls "mended". Isolates the FAIL population review.verdict
    folds back into its "final result" rate: that row asks how sound the work
    shipped overall, this one asks, of the reviews that misfired, how many
    were caught and fixed before the report — the recovery rate a low
    review.verdict number does not by itself distinguish from carelessness.

    byModel attributes a recovery to the model that authored the session under
    review, mirroring score_review_verdict — the same per-session
    approximation, hence the same heuristic tier."""
    author = _run_model(turns)
    mend_cache = _mend_verdicts()
    applied = 0
    complied = 0
    by_model = {}
    for item in _review_fail_items(turns, entry):
        verdict = mend_cache.get(item["key"])
        if verdict not in (MENDED_VERDICT, UNMENDED_VERDICT):
            continue
        applied += 1
        ok = verdict == MENDED_VERDICT
        if ok:
            complied += 1
        _bump_model(by_model, author, ok)
    return applied, complied, by_model


def _unjudged_fails(sessions, entry):
    """FAIL reviews review.recovered could not judge — the judge unreachable,
    or a cache miss it has not warmed yet. Reported beneath the row, mirroring
    _unreviewed_segments for review.verdict, so a low applied count reads as
    "few FAILs to recover" only when that is actually true, not when the
    judging simply never ran."""
    mend_cache = _mend_verdicts()
    return sum(1 for turns in sessions for item in _review_fail_items(turns, entry)
               if mend_cache.get(item["key"]) not in (MENDED_VERDICT, UNMENDED_VERDICT))


def _unreviewed_segments(sessions, entry):
    """The mutating task segments that closed with no review behind them, split
    by why: 'skipped' bears an explicit, reasoned SKIPPED marker; 'silent'
    closed with no verdict at all, or with one no reviewer filed. Reported
    beneath the review.verdict rate as the work it says nothing about — mirrors
    _abandoned_gates for plan.accepted, since a review never run is no verdict
    on the work. Counted per segment, where the rate itself counts reviews:
    one task may draw several reviews, or none."""
    reviewed_re = re.compile(entry["reviewed"])
    skipped_re = re.compile(entry["skipped"]) if entry.get("skipped") else None
    since = entry.get("since", "")
    counts = {"skipped": 0, "silent": 0}
    for turns in sessions:
        review_times = _review_times(turns, reviewed_re, since)
        for seg in _task_segments(_prompt_runs(turns, since)):
            seg_turns = _segment_turns(seg)
            if _segment_complies(seg_turns, reviewed_re, review_times):
                continue
            if skipped_re is not None and _segment_skipped(seg_turns, reviewed_re,
                                                            skipped_re, review_times):
                counts["skipped"] += 1
            else:
                counts["silent"] += 1
    return counts


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


def _request_before(turns, index):
    """The prompt that opened the run a gate was rendered into — the request
    that gate proposed — or None when the gate stands before any prompt.

    A segment opens at a *mutating* run, and under the Free-Form Gate the
    mutating run is the one the user's assent begins: the gauge itself draws no
    edit. So a gate-proposed segment's own opening prompt is "proceed", and the
    words describing the work stand one run earlier. Across the live roots 92 of
    171 completions summarized themselves as bare assent — "proceed" 71 times —
    which no judge can attribute a later bug report to."""
    for j in range(index - 1, -1, -1):
        turn = turns[j]
        if turn["type"] == "user" and _is_run_boundary(turn["text"]):
            return turn["text"]
    return None


def _bug_gate_data(turns, since):
    """One walk over a session's task segments (the same fold _task_segments
    already gives score_task_shot/score_post_gate — called, not modified, so
    those two scorers and their tests stay untouched), returning:
      - completions: [{"key", "summary", "model", "index"}] — every segment
        that counts as a completion this row can hold responsible for a later
        bug report, in transcript order. A segment is a completion when an
        accepted plan.accepted gate proposed it, or it closed with a
        Compliance Review PASS. "summary" is what the judge is shown to
        identify this completion by: the request the gate proposed where a gate
        proposed it (see _request_before), else the segment's own opening
        prompt, which for the gateless path already is the request.
      - reports: [{"key", "candidates", "message"}] — every segment, paired
        with the completions strictly before it (its candidate list) and its
        own opening prompt, for the judge to classify. A segment with no
        completions before it yet is not a report — there is nothing it
        could be describing a defect in.
      - num_segments: the total segment count, so callers can tell which
        completions have a later segment at all to be judged by.

    A gate proposes at most one segment — the first one that follows it —
    walked with a single index-ordered pointer, so a later segment with no
    fresh gate of its own does not inherit an earlier one just because none
    intervened."""
    segments = _task_segments(_prompt_runs(turns, since))
    if not segments:
        return [], [], 0
    review_times = _review_times(turns, COMPLIANCE_VERDICT_RE, since)
    flattened = [_segment_turns(seg) for seg in segments]
    idx_of = {id(t): k for k, t in enumerate(turns)}
    gate_sites = [{"key": s["key"], "index": int(s["key"].rsplit(":", 1)[1])}
                  for s in _gate_sites(turns)]
    plan_verdicts = _verdicts()
    completions = []
    reports = []
    gate_ptr = 0
    for i, seg in enumerate(segments):
        seg_turns = flattened[i]
        seg_start_turn = seg[0][1][0]
        seg_start_idx = idx_of[id(seg_start_turn)]
        session = seg_start_turn.get("session", "")
        key = "%s:%d" % (session, seg_start_idx)
        if completions:
            reports.append({"key": key,
                             "candidates": [{"key": c["key"], "summary": c["summary"]}
                                            for c in completions],
                             "message": seg[0][0]})
        chosen_gate = None
        while gate_ptr < len(gate_sites) and gate_sites[gate_ptr]["index"] < seg_start_idx:
            chosen_gate = gate_sites[gate_ptr]
            gate_ptr += 1
        gate_ok = (chosen_gate is not None
                   and PLAN_VERDICTS.get(plan_verdicts.get(chosen_gate["key"])) is True)
        if gate_ok or _segment_complies(seg_turns, COMPLIANCE_PASS_RE, review_times):
            proposed = _request_before(turns, chosen_gate["index"]) if gate_ok else None
            completions.append({"key": key, "summary": proposed or seg[0][0],
                                 "model": _run_model(seg_turns), "index": i})
    return completions, reports, len(segments)


def score_bug_gate(turns, entry):
    """applied = completions with a later segment in the same transcript to
    observe; complied = those with no later segment's opening prompt judged,
    against the running candidate list of completions before it in that
    session, to report a defect naming this completion as its target. A
    report whose named target matches no candidate counts toward neither
    side — attribution must be certain, not assumed against the nearest
    completion (see _bug_gate_data)."""
    since = entry.get("since", "")
    completions, reports, num_segments = _bug_gate_data(turns, since)
    eligible = [c for c in completions if c["index"] < num_segments - 1]
    if not eligible:
        return 0, 0, {}
    bug_verdicts = _bug_verdicts()
    hit_targets = set()
    for rep in reports:
        verdict = bug_verdicts.get(rep["key"])
        if not verdict or verdict.get("verdict") != BUG_VERDICT or not verdict.get("against"):
            continue
        candidate_keys = {c["key"] for c in rep["candidates"]}
        if verdict["against"] in candidate_keys:
            hit_targets.add(verdict["against"])
    applied = 0
    complied = 0
    by_model = {}
    for c in eligible:
        applied += 1
        ok = c["key"] not in hit_targets
        if ok:
            complied += 1
        _bump_model(by_model, c["model"], ok)
    return applied, complied, by_model


def _pulse_dir():
    """Where the run's history and the verdict cache live. PULSE_DIR is the test
    seam, as it is for the rest of the outputs."""
    return os.environ.get("PULSE_DIR", os.path.expanduser("~/.skadi/pulse"))


def _pending_gates(turns):
    """Every gate in one session, as the judge needs it. All of them go: a gate
    the user answered by picking an option is judged on which option they picked,
    not passed through unweighed."""
    return [{"key": gate["key"], "gauge": gate["gauge"], "reply": gate["reply"]}
            for gate in _gate_sites(turns)]


PLAN_VERDICTS = {"accepted": True, "altered": False}
ABANDONED_VERDICT = "abandoned"

# The two verdicts a bug-gate report may carry. BUG_VERDICT is read at three
# sites — the parser's legal set, the scorer, and the unattributed count — so it
# is bound once rather than retyped.
BUG_VERDICT = "bug"
UNRELATED_VERDICT = "unrelated"

# The two verdicts a mend-judge report may carry — see MEND_JUDGE_PROMPT.
MENDED_VERDICT = "mended"
UNMENDED_VERDICT = "unmended"


def _judged_gates(turns):
    """Every gate in one session that carries a verdict on the plan, as
    (gate, accepted).

    One place decides what counts as a verdict and what counts as acceptance, so
    the headline rate, the per-model split, and the date series cannot drift
    apart. Kept together deliberately: that agreement is the point, and three
    copies of the same filter would hold only until someone edited one of them."""
    verdicts = _verdicts()
    for gate in _gate_sites(turns):
        accepted = PLAN_VERDICTS.get(verdicts.get(gate["key"]))
        if accepted is not None:
            yield gate, accepted


def score_plan_gate(turns, entry):
    """applied = gates whose verdict is a verdict on the plan; complied = those
    the user accepted as proposed.

    A gate the user walked away from is excluded from both sides — silence is no
    verdict — and one the judge could not answer is likewise absent rather than
    guessed (see judged_verdicts). Every gate is judged, including those answered
    by picking an offered option: passing those through as acceptance pinned a
    tenth of the denominator at 100% by construction. The rate answers 'was the
    plan I proposed the right one', not 'was the ritual performed', so it never
    counts a run that owed no gauge."""
    applied = 0
    complied = 0
    by_model = {}
    for gate, ok in _judged_gates(turns):
        applied += 1
        if ok:
            complied += 1
        _bump_model(by_model, gate["model"], ok)
    return applied, complied, by_model


def _gate_series(sessions):
    """The rate's ingredients bucketed by the date each gate happened, oldest
    first, each date carrying its own per-model split.

    The page's existing sparkline plots the date the pulse *ran* and recomputes
    over every session each time, so two dozen runs draw a near-flat line. Filing
    each gate under the day it happened is what lets a week of better plans show
    as a rise. An abandoned gate lands in no bucket, for the same reason it is
    absent from the rate — it shares the headline's one walk, so the chart and the
    headline cannot disagree. A gate whose transcript line carries no timestamp is
    the one exception: it still scores in the headline, because it happened, but it
    cannot be placed on a time axis, and an empty date would sort ahead of every
    real one as a stray leading bucket."""
    series = {}
    for turns in sessions:
        for gate, ok in _judged_gates(turns):
            if not gate["date"]:
                continue
            day = series.setdefault(gate["date"],
                                    {"applied": 0, "complied": 0, "byModel": {}})
            day["applied"] += 1
            if ok:
                day["complied"] += 1
            _bump_model(day["byModel"], gate["model"], ok)
    return {date: {"applied": day["applied"], "complied": day["complied"],
                   "rate": _rate(day["applied"], day["complied"]),
                   "byModel": _rated_by_model(day["byModel"])}
            for date, day in sorted(series.items())}


def _unattributed_bugs(sessions, entry):
    """Reports the judge called a real bug but could pin to no candidate in
    their own list, counted so the row can report them beside the rate rather
    than hide them — mirrors _abandoned_gates for plan.accepted.

    The exclusion is not symmetric with that one, and the count matters more
    for it. A report bears no row of its own; only completions do. So an
    unpinned report does not fall out of the reckoning — the completion it
    actually described stays in `applied` and, unnamed, is scored complied.
    The rate therefore reads high by up to this many, and this count is the
    only thing that says so."""
    since = entry.get("since", "")
    verdicts = _bug_verdicts()
    unattributed = 0
    for turns in sessions:
        for report in _bug_gate_data(turns, since)[1]:
            verdict = verdicts.get(report["key"])
            if not verdict or verdict.get("verdict") != BUG_VERDICT:
                continue
            if verdict.get("against") not in {c["key"] for c in report["candidates"]}:
                unattributed += 1
    return unattributed


def _abandoned_gates(sessions):
    """Gates the user walked away from, counted so the row can report them
    beside the rate rather than hide the exclusion. Not folded into
    _judged_gates: that helper exists to keep the *scored* population identical
    everywhere, and this counts the population it deliberately leaves out."""
    verdicts = _verdicts()
    return sum(1 for turns in sessions for gate in _gate_sites(turns)
               if verdicts.get(gate["key"]) == ABANDONED_VERDICT)


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
            model = _real_model(turn.get("model"))
            if model:
                models.add(model)
    return sorted(models)


JUDGE_PROMPT = """You are grading whether a proposed plan was accepted as proposed.

Each numbered gate below gives the size-gauge block the assistant rendered and
the user's very next reply. Classify each reply as exactly one of:

  accepted  - the user let the plan proceed as proposed: a bare go-ahead
              ("go", "do it", "yes", "proceed", and the same in any language).
  altered   - the user changed what was proposed: narrowed or widened the
              scope, chose a different approach, corrected it, or declined.
              "go, but only touch install.sh" is altered, not accepted.
  abandoned - the reply is no verdict on this plan at all: the user changed
              subject, ran an unrelated command, or never answered.

When the reply reads "Your questions have been answered: ...", the gate offered
the user a choice and this is the option they picked. Weigh which option it was:
the one the gate recommended, or a decision the gate had already committed to, is
accepted; an option that narrows, redirects, or overrides what the gate proposed
is altered. Do not treat a recorded answer as acceptance merely because an answer
was given.

Reply with a JSON array and nothing else:
[{"key": "<the key given>", "verdict": "accepted|altered|abandoned"}]
"""


def _judge_argv():
    """The judging command line. PULSE_JUDGE_CMD is the test seam; either way
    the prompt arrives on stdin and JSON is expected on stdout."""
    return shlex.split(os.environ.get("PULSE_JUDGE_CMD", "claude -p"))


def _ask_judge(prompt):
    """One batched call. Returns the judge's stdout, or '' when no model
    answers — the caller leaves those gates unjudged rather than guess."""
    try:
        done = subprocess.run(_judge_argv(), input=prompt, capture_output=True,
                              text=True, encoding="utf-8", errors="replace",
                              timeout=JUDGE_TIMEOUT)
    except (OSError, ValueError, subprocess.SubprocessError) as err:
        print("pulse-scan: judge unreachable (%s)" % err, file=sys.stderr)
        return ""
    if done.returncode != 0:
        print("pulse-scan: judge exited %d: %s"
              % (done.returncode, done.stderr.strip()[:200]), file=sys.stderr)
        return ""
    return done.stdout


def _parse_verdicts(raw):
    """The JSON array a judge returned, as {key: verdict}. Anything that is not
    a legal verdict is dropped, so a malformed answer costs coverage rather
    than correctness."""
    start, end = raw.find("["), raw.rfind("]")
    if start == -1 or end <= start:
        return {}
    try:
        rows = json.loads(raw[start:end + 1])
    except ValueError:
        return {}
    legal = tuple(PLAN_VERDICTS) + (ABANDONED_VERDICT,)
    return {row["key"]: row["verdict"] for row in rows
            if isinstance(row, dict) and row.get("key")
            and row.get("verdict") in legal}


def _judge_batch(batch):
    parts = [JUDGE_PROMPT]
    for gate in batch:
        parts.append("--- key: %s\ngauge:\n%s\n\nreply:\n%s\n"
                     % (gate["key"], gate["gauge"][:1200],
                        gate["reply"][:800] or "(no reply)"))
    return _parse_verdicts(_ask_judge("\n".join(parts)))


BUG_JUDGE_PROMPT = """You are grading whether a later message in a coding assistant
transcript reports a defect in previously-completed work, and if so, which
earlier completion it targets.

Each numbered report below gives a list of candidate completions from earlier
in the same session (a short one-line summary and a candidate key each), and
the opening message of a later piece of work in that session. Classify each
report as exactly one of:

  bug       - the message reports a defect, failure, or something not working
              correctly in one of the listed candidates. Set "against" to that
              candidate's key.
  unrelated - the message is a new request, a follow-up feature, a question,
              or anything else that is not reporting a defect in prior work.

When the verdict is "bug" but no listed candidate is clearly the one being
described, still answer "bug" and set "against" to null — do not guess a
candidate just to fill the field; a wrong attribution is worse than an absent
one.

Reply with a JSON array and nothing else:
[{"key": "<the key given>", "verdict": "bug|unrelated", "against": "<candidate key or null>"}]
"""


def _parse_bug_verdicts(raw):
    """The JSON array a judge returned, as {key: {"verdict":..., "against":...}}.
    Anything that is not a legal verdict is dropped, so a malformed answer
    costs coverage rather than correctness. An "against" that is not a string
    (missing, null, or the judge inventing a non-string value) becomes None —
    attribution must be certain, not guessed."""
    start, end = raw.find("["), raw.rfind("]")
    if start == -1 or end <= start:
        return {}
    try:
        rows = json.loads(raw[start:end + 1])
    except ValueError:
        return {}
    out = {}
    for row in rows:
        if not isinstance(row, dict) or not row.get("key") or row.get("verdict") not in (BUG_VERDICT, UNRELATED_VERDICT):
            continue
        against = row.get("against")
        out[row["key"]] = {"verdict": row["verdict"],
                            "against": against if isinstance(against, str) else None}
    return out


def _bug_judge_batch(batch):
    parts = [BUG_JUDGE_PROMPT]
    for report in batch:
        candidates = "\n".join("  %s: %s" % (c["key"], c["summary"][:200])
                                for c in report["candidates"])
        parts.append("--- key: %s\ncandidates:\n%s\n\nmessage:\n%s\n"
                     % (report["key"], candidates, report["message"][:800]))
    return _parse_bug_verdicts(_ask_judge("\n".join(parts)))


MEND_JUDGE_PROMPT = """You are grading whether a Compliance Review's FAIL
findings were mended before the task's segment closed.

Each item below gives the reviewer's own findings and everything the main
thread did in that same segment afterward. Classify each as exactly one of:

  mended    - the findings (or the specific defects they named) were
              addressed by an edit or an explicit fix afterward. A partial fix
              that still leaves a named finding's core defect open is
              unmended.
  unmended  - nothing afterward addresses the findings, or the segment closed
              with the same defect still standing.

Reply with a JSON array and nothing else:
[{"key": "<the key given>", "verdict": "mended|unmended"}]
"""


def _parse_mend_verdicts(raw):
    """The JSON array a judge returned, as {key: "mended"|"unmended"}.
    Anything that is not a legal verdict is dropped, so a malformed answer
    costs coverage rather than correctness — mirrors _parse_verdicts /
    _parse_bug_verdicts."""
    start, end = raw.find("["), raw.rfind("]")
    if start == -1 or end <= start:
        return {}
    try:
        rows = json.loads(raw[start:end + 1])
    except ValueError:
        return {}
    legal = (MENDED_VERDICT, UNMENDED_VERDICT)
    return {row["key"]: row["verdict"] for row in rows
            if isinstance(row, dict) and row.get("key") and row.get("verdict") in legal}


def _mend_judge_batch(batch):
    parts = [MEND_JUDGE_PROMPT]
    for item in batch:
        parts.append("--- key: %s\nfindings:\n%s\n\nafterward:\n%s\n"
                     % (item["key"], item["findings"][:1200],
                        item["context"][:1200] or "(nothing followed)"))
    return _parse_mend_verdicts(_ask_judge("\n".join(parts)))


def _load_verdicts(path):
    """The cached verdicts, or {} when there are none. A cache that will not
    parse is set aside as <path>.corrupt rather than silently read as empty:
    losing it means paying for the whole backfill again, so the loss is made
    visible instead of quietly absorbed."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            cache = json.load(fh)
    except OSError as err:
        print("pulse-scan: cannot read %s: %s" % (path, err), file=sys.stderr)
        return {}
    except ValueError:
        cache = None
    if isinstance(cache, dict):
        return cache
    os.replace(path, path + ".corrupt")
    print("pulse-scan: %s did not parse — set aside as %s.corrupt, re-judging"
          % (path, path), file=sys.stderr)
    return {}


def _save_verdicts(path, cache):
    """Written whole, then renamed into place. A half-written cache reads as
    corrupt on the next run and costs the entire backfill; os.replace is atomic
    on both POSIX and Windows, so a reader sees the old file or the new one."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cache, fh, ensure_ascii=False, sort_keys=True)
    os.replace(tmp, path)
    _VERDICTS_MEMO.pop(path, None)


_VERDICTS_MEMO = {}


def _cached_verdicts(path):
    """The judged-verdict cache at `path`, parsed once per process. Scorers run
    once per session — 800 of them in production — and a cache only grows, so
    reading it per call would parse the same file 800 times. Keyed by path so
    plan-gate's verdicts.json and bug-gate's bug-verdicts.json get their own
    slot (as does a test pointing PULSE_DIR elsewhere); dropped on write, so a
    warmed cache is re-read rather than served stale."""
    if path not in _VERDICTS_MEMO:
        _VERDICTS_MEMO[path] = _load_verdicts(path)
    return _VERDICTS_MEMO[path]


def _verdicts():
    return _cached_verdicts(os.path.join(_pulse_dir(), "verdicts.json"))


def _bug_verdicts():
    return _cached_verdicts(os.path.join(_pulse_dir(), "bug-verdicts.json"))


def _mend_verdicts():
    return _cached_verdicts(os.path.join(_pulse_dir(), "mend-verdicts.json"))


def _judge_pending(pending, path, batch_fn):
    """{key: value} for the given items, judged once and cached on disk at
    path. A closed transcript never changes, so a verdict keyed by session and
    turn is written once and read by every run after: the first pass pays for
    the backfill, later passes call no model at all. Shared by plan-gate and
    bug-gate — only the batch-judging function and the value shape it returns
    differ. Items the judge could not answer are simply absent from the
    result — there is no keyword fallback, because a silent one would change
    what the number means without saying so."""
    cache = _load_verdicts(path)
    fresh = [item for item in pending if item["key"] not in cache]
    for start in range(0, len(fresh), JUDGE_BATCH):
        answered = batch_fn(fresh[start:start + JUDGE_BATCH])
        if answered:
            # Checkpointed per batch, not once at the end: a backfill is many
            # sequential calls, and a kill partway through must not throw away
            # every verdict already paid for.
            cache.update(answered)
            _save_verdicts(path, cache)
    return {item["key"]: cache[item["key"]]
            for item in pending if item["key"] in cache}


def judged_verdicts(pending, pulse_dir):
    """Plan-gate verdicts: {key: "accepted"|"altered"|"abandoned"}."""
    return _judge_pending(pending, os.path.join(pulse_dir, "verdicts.json"), _judge_batch)


def judged_bug_verdicts(pending, pulse_dir):
    """Bug-gate verdicts: {key: {"verdict": "bug"|"unrelated", "against": key or None}}."""
    return _judge_pending(pending, os.path.join(pulse_dir, "bug-verdicts.json"), _bug_judge_batch)


def judged_mend_verdicts(pending, pulse_dir):
    """Mend verdicts: {key: "mended"|"unmended"}."""
    return _judge_pending(pending, os.path.join(pulse_dir, "mend-verdicts.json"), _mend_judge_batch)


def _warm_gate_verdicts(sessions):
    """Judge every unjudged gate across all sessions in one pass, so the
    per-session scorer afterwards finds a warm cache and calls no model. Judging
    inside the scorer would turn one batched call into one call per session."""
    pending = [gate for turns in sessions for gate in _pending_gates(turns)]
    if pending:
        judged_verdicts(pending, _pulse_dir())


def _warm_bug_verdicts(sessions, since):
    """Judge every unjudged bug-report candidate across all sessions in one
    pass, mirroring _warm_gate_verdicts — the per-session scorer afterwards
    finds a warm cache and calls no model."""
    pending = [rep for turns in sessions for rep in _bug_gate_data(turns, since)[1]]
    if pending:
        judged_bug_verdicts(pending, _pulse_dir())


def _warm_mend_verdicts(sessions, entry):
    """Judge every unjudged FAIL review across all sessions in one pass,
    mirroring _warm_bug_verdicts — the per-session scorers (review.verdict,
    review.recovered) afterwards find a warm cache and call no model."""
    pending = [item for turns in sessions for item in _review_fail_items(turns, entry)]
    if pending:
        judged_mend_verdicts(pending, _pulse_dir())


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
               "review-verdict": score_review_verdict,
               "review-recovered": score_review_recovered,
               "task-shot": score_task_shot, "plan-gate": score_plan_gate,
               "bug-gate": score_bug_gate}
    sessions = [read_turns(f) for f in files]
    session_is_sweep = [_is_sweep_session(turns) for turns in sessions]
    if any(entry["kind"] == "plan-gate" for entry in rubric):
        _warm_gate_verdicts(sessions)
    bug_entry = next((e for e in rubric if e["kind"] == "bug-gate"), None)
    if bug_entry is not None:
        _warm_bug_verdicts(sessions, bug_entry.get("since", ""))
    mend_entry = next((e for e in rubric if e["kind"] in ("review-verdict", "review-recovered")), None)
    if mend_entry is not None:
        _warm_mend_verdicts(sessions, mend_entry)
    items = []
    for entry in rubric:
        kind = entry["kind"]
        base = {"id": entry["id"], "label": entry["label"],
                "tier": entry["tier"], "kind": kind,
                "criterion": entry.get("criterion", ""),
                "labelZh": entry.get("label_zh", ""),
                "criterionZh": entry.get("criterion_zh", "")}
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
            if kind == "plan-gate":
                item["abandoned"] = _abandoned_gates(sessions)
                item["byDate"] = _gate_series(sessions)
            if kind == "bug-gate":
                item["unattributed"] = _unattributed_bugs(sessions, entry)
            if kind == "post-gate" and entry.get("skipped"):
                item["skipped"] = _skipped_reviews(sessions, entry)
            if kind == "review-verdict":
                item["unreviewed"] = _unreviewed_segments(sessions, entry)
            if kind == "review-recovered":
                item["unjudged"] = _unjudged_fails(sessions, entry)
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
    return ["~/.claude", "~/.claude-personal", "~/.claude-work",
            "~/.codex", "~/.codex-personal", "~/.codex-work"]


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
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 16 16%22><text y=%2213%22 font-size=%2214%22>%F0%9F%93%8A</text></svg>">
<style>
  body{font-family:ui-sans-serif,system-ui,sans-serif;margin:1.2rem;}
  .kpi{font-size:2.4rem;font-weight:700;}
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
  .gaterow td{background:rgba(203,184,154,.10);border-bottom:1px solid #cbb89a;}
  .gatewrap{display:flex;gap:1.1rem;align-items:flex-start;flex-wrap:wrap;padding:.35rem .1rem .55rem;}
  .gatewrap svg{background:rgba(203,184,154,.14);border:1px solid #cbb89a;border-radius:3px;}
  .gaxis{font:400 8px/1 ui-sans-serif,system-ui,sans-serif;fill:#87795e;}
  .glegend{font-size:.72rem;color:#4a4235;}
  .glegend div{margin:.2rem 0;white-space:nowrap;}
  .glegend i{display:inline-block;width:.85rem;height:.18rem;vertical-align:middle;margin-right:.35rem;}
  .glegend b{font-variant-numeric:tabular-nums;}
  .gnote{font-size:.72rem;color:#87795e;font-style:italic;margin:.15rem 0 0;}
  .gempty{font-size:.78rem;color:#87795e;font-style:italic;padding:.55rem .1rem;}
  .headerrow{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:.5rem;}
  .langswitch{display:flex;gap:.35rem;}
</style>
<div class="headerrow">
  <h1 id="pageTitle">Adherence Pulse</h1>
  <div class="langswitch" id="langSwitch">
    <button class="chip" data-lang="en">EN</button>
    <button class="chip" data-lang="zh">中文</button>
  </div>
</div>
<div class="tabs" id="tabs">
  <button class="tabbtn active" data-tab="direct">Direct</button>
  <button class="tabbtn" data-tab="sweep">Sweep</button>
</div>
<div class="modelchips" id="modelchips"></div>
<div class="tabnote" id="tabnote"></div>
<div class="kpi" id="overall">—</div>
<div class="trendlabel" id="trendlabel">trend, by run date</div>
<svg id="spark" width="320" height="60"></svg>
<table>
  <thead><tr><th id="colItem">Item</th><th id="colRate">Rate</th><th id="colN">n</th></tr></thead>
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

const STRINGS = {
  en: {
    title: "Adherence Pulse",
    tabDirect: "Direct", tabSweep: "Sweep",
    trend: "trend, by run date",
    colItem: "Item", colRate: "Rate", colN: "n",
    overall: "Overall",
    pending: "pending", error: "error", noSweep: "no sweep data", noData: "no data",
    infoTitle: "What counts as success / failure",
    modelNote: (m) => ` · showing only ${m}'s runs, recomputed independently.`,
    tabNotes: {
      direct: "workflow rows count sessions with no /loop or /amon-sul in them — a hand-typed command inside such a session is still counted as sweep.",
      sweep: "workflow rows only — grammar and free-form gate rows carry no sweep concept, so they're dropped from this tab.",
    },
    tiers: { heuristic: "heuristic", structural: "structural", deterministic: "deterministic" },
    gateEmpty: "No plan gate has been judged yet — the rate and its trend fill in as gauges are answered.",
    gateAbandoned: (n) => `${n} gate${n === 1 ? "" : "s"} abandoned — excluded from the rate, since silence is no verdict on a plan.`,
    reviewExcluded: (silent, skipped) => `Excluded from this rate: ${silent} segment${silent === 1 ? "" : "s"} closed with no review${skipped ? `, ${skipped} explicitly skipped` : ""} — a review never run is no verdict on the work.`,
    reviewWaived: (n) => `${n} segment${n === 1 ? "" : "s"} waived the review with a reasoned SKIPPED — excluded from this rate, neither credited nor penalized.`,
    bugUnattributed: (n) => `${n} bug report${n === 1 ? "" : "s"} named no completion — each still counts its target clean, so this rate reads high by up to that many.`,
    day: (n) => `${n} day${n === 1 ? "" : "s"}`,
    gateAria: "Plan acceptance rate by session date, one line per model",
  },
  zh: {
    title: "遵循度脈動",
    tabDirect: "直接", tabSweep: "掃描",
    trend: "趨勢（依執行日期）",
    colItem: "項目", colRate: "比率", colN: "n",
    overall: "總體",
    pending: "待建", error: "錯誤", noSweep: "無掃描資料", noData: "無資料",
    infoTitle: "什麼算通過／未通過",
    modelNote: (m) => `．僅顯示 ${m} 的執行紀錄，獨立重新計算。`,
    tabNotes: {
      direct: "workflow 類項目計入沒有 /loop 或 /amon-sul 的 session——這類 session 裡手動輸入的指令仍算作 sweep。",
      sweep: "只涵蓋 workflow 類項目——grammar 與 free-form gate 沒有 sweep 的概念，因此不列入這個分頁。",
    },
    tiers: { heuristic: "啟發式", structural: "結構性", deterministic: "確定性" },
    gateEmpty: "尚未有任何計畫關卡被判定——比率與趨勢會隨著量表被回答而逐漸填入。",
    gateAbandoned: (n) => `${n} 個關卡遭放棄——不計入比率，沉默不代表對計畫的任何判決。`,
    reviewExcluded: (silent, skipped) => `不計入此比率：${silent} 個段落未經審查即收尾${skipped ? `，另有 ${skipped} 個明示略過` : ""}——未曾進行的審查，對成果不構成任何判決。`,
    reviewWaived: (n) => `${n} 個段落以具名理由的 SKIPPED 免除審查——不計入此比率，既不記功亦不記過。`,
    bugUnattributed: (n) => `${n} 筆缺陷回報指不出對應的完成項——它們的目標仍被算作乾淨，因此此比率最多高估這麼多。`,
    day: (n) => `${n} 天`,
    gateAria: "依 session 日期呈現的計畫接受率，每個模型一條線",
  },
};
let currentLang = (navigator.language || "en").toLowerCase().startsWith("zh") ? "zh" : "en";
const S = () => STRINGS[currentLang];
const statusLabel = (status) => ({
  pending: S().pending, error: S().error, "no-sweep": S().noSweep, "no-data": S().noData,
}[status] || status);
const tierLabel = (t) => S().tiers[t] || t;
const itemLabel = (i) => (currentLang === "zh" && i.labelZh) ? i.labelZh : i.label;
const itemCriterion = (i) => (currentLang === "zh" && i.criterionZh) ? i.criterionZh : i.criterion;

const MODEL_LABELS = {
  "claude-opus-4-8": "Opus 4.8",
  "claude-sonnet-5": "Sonnet 5",
  "claude-fable-5": "Fable 5",
  "gpt-5.6-sol": "Codex Sol",
  "gpt-5.6-terra": "Codex Terra",
  "gpt-5.6-luna": "Codex Luna",
};
const modelLabel = (m) => m === "Overall" ? S().overall : (MODEL_LABELS[m] || m);

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

// "Overall" is an aggregate, not a peer of the models, so it wears neutral ink;
// only the models take a categorical hue. Hues are assigned in this fixed order
// and never cycled — a fourth model folds into one muted "other" rather than
// repeating a colour and lying about identity. Validated with the dataviz
// palette checker on a light surface: all six checks pass, worst adjacent pair
// ΔE 23.3 under protanopia and 24.0 with normal vision. The theme's own brown
// and green failed that check at ΔE 2.4, which is why these are not them.
const GATE_HUES = ["#1a5fb4", "#a8551a", "#6b3fa0"];
const GATE_OTHER = "#87795e";
const GATE_INK = "#4a4235";

// Roster order first, then anything unrecognised — so a hue belongs to a model,
// not to its rank in the data, and adding a model never repaints the others.
function gateModels(byDate, dates) {
  const seen = new Set();
  dates.forEach(d => Object.keys(byDate[d].byModel || {}).forEach(m => seen.add(m)));
  const roster = Object.keys(MODEL_LABELS);
  return roster.filter(m => seen.has(m)).concat([...seen].filter(m => !roster.includes(m)));
}

function gateSeries(item) {
  const dates = Object.keys(item.byDate || {});
  if (!dates.length) return [];
  const models = gateModels(item.byDate, dates);
  const at = (d, m) => m === null ? item.byDate[d] : (item.byDate[d].byModel || {})[m];
  const build = (label, m, colour) => {
    const cells = dates.map(d => ({ date: d, cell: at(d, m) })).filter(p => p.cell);
    // The legend carries the series' total across the window, not its last point.
    // Showing the latest day there made every line read "100%" beside a headline
    // of 73% — numbers that look like totals must be totals.
    const applied = cells.reduce((a, p) => a + p.cell.applied, 0);
    const complied = cells.reduce((a, p) => a + p.cell.complied, 0);
    return {
      label, colour, model: m, applied, complied,
      rate: applied ? Math.round(100 * complied / applied) : null,
      points: cells.map(p => ({ date: p.date, rate: p.cell.rate,
                                n: p.cell.complied + "/" + p.cell.applied })),
    };
  };
  const out = [build(modelLabel("Overall"), null, GATE_INK)];
  models.forEach((m, k) => out.push(
    build(modelLabel(m), m, k < GATE_HUES.length ? GATE_HUES[k] : GATE_OTHER)));
  return out.filter(s => s.points.length);
}

const GATE_BOX = { W: 300, H: 74, L: 26, B: 15, T: 7 };

function gateScales(dates) {
  const { W, H, L, B, T } = GATE_BOX;
  return {
    x: (d) => dates.length > 1
      ? L + (dates.indexOf(d) / (dates.length - 1)) * (W - L - 6) : L + (W - L - 6) / 2,
    y: (v) => T + (1 - v / 100) * (H - B - T),
  };
}

// The selected model's line draws at full strength; the rest dim to a faint
// wash rather than vanish outright — the point is comparison at a glance
// ("was this model the outlier"), which a hidden line can't answer. The
// selected line draws last so it never sits under a dimmed one.
const GATE_DIM_OPACITY = 0.22;

function gateLines(series, scale, selectedModel) {
  const isSelected = (s) =>
    selectedModel === "Overall" ? s.model === null : s.model === selectedModel;
  const ordered = [...series].sort((a, b) => isSelected(a) - isSelected(b));
  return ordered.map(s => {
    const dim = !isSelected(s);
    const opacity = dim ? GATE_DIM_OPACITY : 1;
    const at = (p) => `${scale.x(p.date).toFixed(1)},${scale.y(p.rate).toFixed(1)}`;
    const dots = s.points.map(p =>
      `<circle cx="${scale.x(p.date).toFixed(1)}" cy="${scale.y(p.rate).toFixed(1)}" r="4"
        fill="${s.colour}" fill-opacity="${opacity}" stroke="rgba(252,252,251,.9)"
        stroke-opacity="${opacity}" stroke-width="2"
        ><title>${esc(s.label)} · ${esc(p.date)} · ${esc(p.rate)}% (${esc(p.n)})</title></circle>`).join("");
    return `<polyline fill="none" stroke="${s.colour}" stroke-opacity="${opacity}" stroke-width="2"
      stroke-linejoin="round" points="${s.points.map(at).join(" ")}"/>${dots}`;
  }).join("");
}

function gateLegend(series, abandoned) {
  const rows = series.map(s =>
    `<div><i style="background:${s.colour}"></i>${esc(s.label)} — <b>${esc(s.rate)}%</b>
      <span class="gaxis">${esc(s.complied)}/${esc(s.applied)} over ${esc(S().day(s.points.length))}</span></div>`);
  if (abandoned) {
    rows.push(`<p class="gnote">${esc(S().gateAbandoned(abandoned))}</p>`);
  }
  return rows.join("");
}

function gateChart(item, model) {
  const series = gateSeries(item);
  if (!series.length) {
    return `<div class="gempty">${esc(S().gateEmpty)}</div>`;
  }
  const dates = [...new Set(series.flatMap(s => s.points.map(p => p.date)))].sort();
  const { W, H, L, B, T } = GATE_BOX;
  return `<div class="gatewrap">
    <svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="${esc(S().gateAria)}">
      <line x1="${L}" y1="${T}" x2="${L}" y2="${H - B}" stroke="#cbb89a"/>
      <line x1="${L}" y1="${H - B}" x2="${W - 4}" y2="${H - B}" stroke="#cbb89a"/>
      <text class="gaxis" x="2" y="${T + 4}">100</text>
      <text class="gaxis" x="14" y="${H - B + 3}">0</text>
      ${gateLines(series, gateScales(dates), model)}
      <text class="gaxis" x="${L}" y="${H - 4}">${esc(dates[0])}</text>
      ${dates.length > 1 ? `<text class="gaxis" x="${W - 4}" y="${H - 4}"
        text-anchor="end">${esc(dates[dates.length - 1])}</text>` : ""}
    </svg>
    <div class="glegend">${gateLegend(series, item.abandoned)}</div>
  </div>`;
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
  const modelNote = model === "Overall" ? "" : S().modelNote(modelLabel(model));
  document.getElementById("tabnote").textContent = S().tabNotes[tab] + modelNote;
  document.getElementById("modelchips").innerHTML = ["Overall", ...DATA.models].map(m =>
    `<button class="chip ${m === model ? "active" : ""}" data-model="${esc(m)}">${esc(modelLabel(m))}</button>`
  ).join("");
  const items = applyModel(viewFor(DATA.items, tab), model);
  const rated = items.filter(i => typeof i.rate === "number");
  const overall = rated.length ? Math.round(rated.reduce((a,i)=>a+i.rate,0)/rated.length) : null;
  document.getElementById("overall").textContent = overall == null ? "—" : overall + "%";
  document.getElementById("trendlabel").textContent =
    `${S().trend} · ${tab === "sweep" ? S().tabSweep : S().tabDirect} · ${modelLabel(model)}`;
  renderTrend(tab, model);

  const groups = {};
  items.forEach(i => { (groups[i.tier] = groups[i.tier] || []).push(i); });
  const rowHtml = (i) => {
    const rate = i.status !== "ok" ? statusLabel(i.status) : (i.rate == null ? "—" : i.rate + "%");
    const n = i.applied == null ? "" : i.complied + " / " + i.applied;
    const bar = typeof i.rate === "number" ? `<div class="meter"><i style="width:${i.rate}%"></i></div>` : "";
    const statusBadge = i.status !== "ok" ? `<span class="badge ${esc(i.status)}">${esc(statusLabel(i.status))}</span>` : "";
    const info = i.criterion ? `<button class="info" data-info="${esc(i.id)}" title="${esc(S().infoTitle)}">&#9432;</button>` : "";
    // The exclusion stands beside the rate rather than behind the ⓘ: a rate
    // read without knowing how many segments never earned a verdict misleads.
    const excluded = i.unreviewed && (i.unreviewed.silent + i.unreviewed.skipped) > 0
      ? `<p class="gnote">${esc(S().reviewExcluded(i.unreviewed.silent, i.unreviewed.skipped))}</p>` : "";
    const waived = i.skipped ? `<p class="gnote">${esc(S().reviewWaived(i.skipped))}</p>` : "";
    const unpinned = i.unattributed ? `<p class="gnote">${esc(S().bugUnattributed(i.unattributed))}</p>` : "";
    const critRow = i.criterion ? `<tr class="critrow" data-crit="${esc(i.id)}"><td colspan="3"><div class="crit">${criterionHtml(itemCriterion(i))}</div></td></tr>` : "";
    // The rate above obeys the selected chip, as every row does; the chart below
    // still draws every model's line — comparing them costs no clicks — but dims
    // every line except the selected one's, so the chip's choice reads there too.
    const gateRow = i.byDate !== undefined
      ? `<tr class="gaterow"><td colspan="3">${gateChart(i, model)}</td></tr>` : "";
    return `<tr class="${i.status !== "ok" ? "pending" : ""}">
      <td><code>${esc(i.id)}</code> ${info} ${statusBadge}<br>${esc(itemLabel(i))}${bar}${excluded}${waived}${unpinned}</td>
      <td>${esc(rate)}</td><td>${esc(n)}</td></tr>${critRow}${gateRow}`;
  };
  document.getElementById("rows").innerHTML = Object.keys(groups).sort((a, b) => tierRank(a) - tierRank(b)).map(t =>
    `<tr class="tiergroup"><td colspan="3">${esc(tierLabel(t))}</td></tr>` + groups[t].map(rowHtml).join("")
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

function applyChrome() {
  document.title = S().title;
  document.getElementById("pageTitle").textContent = S().title;
  document.querySelectorAll("#langSwitch .chip").forEach(b => {
    b.classList.toggle("active", b.dataset.lang === currentLang);
  });
  document.querySelectorAll(".tabbtn").forEach(b => {
    b.textContent = b.dataset.tab === "sweep" ? S().tabSweep : S().tabDirect;
  });
  document.getElementById("colItem").textContent = S().colItem;
  document.getElementById("colRate").textContent = S().colRate;
  document.getElementById("colN").textContent = S().colN;
}
document.getElementById("langSwitch").addEventListener("click", (e) => {
  const btn = e.target.closest(".chip");
  if (!btn || btn.dataset.lang === currentLang) return;
  currentLang = btn.dataset.lang;
  applyChrome();
  render(currentTab, currentModel);
});
applyChrome();
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
    rubric_path = os.environ.get("PULSE_RUBRIC", os.path.join(here, "pulse-rubric.json"))
    rubric = json.load(open(rubric_path, encoding="utf-8"))
    now = datetime.now(timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    pulse_dir = _pulse_dir()
    board_dir = os.environ.get("BOARD_DIR", os.path.expanduser("~/.skadi/board"))
    henneth_dir = os.environ.get("HENNETH_DIR", os.path.expanduser("~/.skadi/henneth"))
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
